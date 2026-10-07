# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class ForwardingCheckerTest < Minitest::Test
  RUBY3 = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0")

  BROKEN_CHAIN = <<~RUBY
    class Chain
      def target(*args, **kwargs)
        [args, kwargs]
      end

      def entry(*args)
        target(*args)
      end
    end
  RUBY

  FLAGGED_CHAIN = <<~RUBY
    class Chain
      def target(*args, **kwargs)
        [args, kwargs]
      end

      def entry(*args)
        target(*args)
      end
      ruby2_keywords :entry
    end
  RUBY

  FORWARD_ALL_CHAIN = <<~RUBY
    class Chain
      def target(*args, **kwargs)
        [args, kwargs]
      end

      def entry(...)
        target(...)
      end
    end
  RUBY

  PROBE = <<~RUBY
    result = Chain.new.entry(1, 2, k: 3)
    if result == [[1, 2], { k: 3 }]
      puts "ARRIVAL_OK"
    else
      puts "ARRIVAL_MISMATCH \#{result.inspect}"
    end
  RUBY

  def check(source, target_version: "3.0")
    SyntaxTree::ForwardingChecker.new(target_version: target_version).check(
      source
    )
  end

  # Runs a small, fixed Ruby program in a subprocess and returns its stdout,
  # so tests compare the arguments that actually arrive at the final callee
  # instead of only inspecting the AST.
  def run_ruby(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "probe.rb")
      File.write(path, source)

      capture = -> { Open3.capture3(RbConfig.ruby, path) }
      out, err, status =
        if defined?(Bundler)
          Bundler.with_unbundled_env(&capture)
        else
          capture.call
        end

      assert_predicate(status, :success?, "probe failed to run: #{err}")
      out
    end
  end

  def arrival(source)
    run_ruby(source + PROBE)
  end

  def test_reports_role_of_each_forwarding_element
    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        def broken(*args)
          target(*args)
        end

        def flagged(*args)
          target(*args)
        end
        ruby2_keywords :flagged

        def fwd(...)
          target(...)
        end
      end
    RUBY

    report = check(source)

    star = report.roles.find { |entry| entry.element == "*args" }
    assert(star, "expected a role entry for *args")
    assert_includes(star.message, "captures positional arguments")

    r2k = report.roles.find { |entry| entry.element == "ruby2_keywords" }
    assert(r2k, "expected a role entry for ruby2_keywords")
    assert_includes(r2k.message, "flags the final positional Hash")

    dots = report.roles.find { |entry| entry.element == "..." }
    assert(dots, "expected a role entry for ...")
    assert_includes(dots.message, "forwards all arguments")
  end

  def test_splat_only_forwarding_is_an_issue_on_ruby3
    report = check(BROKEN_CHAIN)

    assert_equal(1, report.issues.size)
    issue = report.issues.first
    assert_equal("*args", issue.element)
    assert_equal("Chain::entry", issue.method_name)
    assert_includes(issue.message, "will not receive them as keywords")

    fixed = issue.suggestion.apply(BROKEN_CHAIN)
    assert_includes(fixed, "def entry(*args, **kwargs)")
    assert_includes(fixed, "target(*args, **kwargs)")
  end

  def test_keyword_arrival_before_and_after_migration
    skip "requires Ruby >= 3.0 semantics" unless RUBY3

    before = arrival(BROKEN_CHAIN)
    assert_includes(before, "ARRIVAL_MISMATCH")
    assert_includes(before, "[[1, 2, {:k=>3}], {}]")

    report = check(BROKEN_CHAIN)
    suggestion = report.issues.first.suggestion
    assert(suggestion, "expected a provable fix for the broken chain")

    after = arrival(suggestion.apply(BROKEN_CHAIN))
    assert_includes(after, "ARRIVAL_OK")
  end

  def test_anonymous_splat_chain_migration
    skip "requires Ruby >= 3.0 semantics" unless RUBY3

    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        def entry(*)
          target(*)
        end
      end
    RUBY

    assert_includes(arrival(source), "ARRIVAL_MISMATCH")

    suggestion = check(source).issues.first.suggestion
    fixed = suggestion.apply(source)
    assert_includes(fixed, "def entry(*args, **kwargs)")
    assert_includes(fixed, "target(*args, **kwargs)")
    assert_includes(arrival(fixed), "ARRIVAL_OK")
  end

  def test_ruby2_keywords_removal_preserves_arrival
    skip "requires Ruby >= 3.0 semantics" unless RUBY3

    assert_includes(arrival(FLAGGED_CHAIN), "ARRIVAL_OK")

    report = check(FLAGGED_CHAIN)
    assert_empty(report.issues)

    suggestion = report.suggestions.first
    assert(suggestion, "expected a ruby2_keywords cleanup suggestion")

    fixed = suggestion.apply(FLAGGED_CHAIN)
    refute_includes(fixed, "ruby2_keywords")
    assert_includes(fixed, "def entry(*args, **kwargs)")
    assert_includes(arrival(fixed), "ARRIVAL_OK")
  end

  def test_inline_ruby2_keywords_def_form
    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        ruby2_keywords def entry(*args)
          target(*args)
        end
      end
    RUBY

    report = check(source)
    suggestion = report.suggestions.first
    assert(suggestion, "expected a cleanup suggestion for the inline form")

    fixed = suggestion.apply(source)
    refute_includes(fixed, "ruby2_keywords")
    assert_includes(fixed, "def entry(*args, **kwargs)")
    assert_includes(arrival(fixed), "ARRIVAL_OK") if RUBY3
  end

  def test_forward_all_chain_needs_no_changes
    report = check(FORWARD_ALL_CHAIN)

    assert_empty(report.issues)
    assert_empty(report.unresolvable)
    assert_empty(report.suggestions)
    assert_includes(arrival(FORWARD_ALL_CHAIN), "ARRIVAL_OK") if RUBY3
  end

  def test_explicit_kwargs_chain_needs_no_changes
    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        def entry(*args, **kwargs)
          target(*args, **kwargs)
        end
      end
    RUBY

    report = check(source)
    assert_empty(report.issues)
    assert_empty(report.suggestions)
    assert_includes(arrival(source), "ARRIVAL_OK") if RUBY3
  end

  def test_dynamic_send_keeps_explanation_without_suggestion
    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        def entry(name, *args)
          send(name, *args)
        end
      end
    RUBY

    report = check(source)
    assert_empty(report.issues)
    assert_empty(report.suggestions)

    assert_equal(1, report.unresolvable.size)
    entry = report.unresolvable.first
    assert_equal("send", entry.element)
    assert_includes(entry.message, "dynamic dispatch")
  end

  def test_unknown_callee_keeps_explanation_without_suggestion
    source = <<~RUBY
      class Chain
        def entry(*args)
          somewhere_else(*args)
        end
      end
    RUBY

    report = check(source)
    assert_empty(report.issues)
    assert_empty(report.suggestions)

    assert_equal(1, report.unresolvable.size)
    assert_includes(report.unresolvable.first.message, "not defined")
  end

  def test_ruby2_keywords_kept_when_chain_has_dynamic_hop
    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        def entry(name, *args)
          send(name, *args)
        end
        ruby2_keywords :entry
      end
    RUBY

    report = check(source)
    assert_empty(report.suggestions)

    kept =
      report.unresolvable.find { |entry| entry.element == "ruby2_keywords" }
    assert(kept, "expected ruby2_keywords to be reported as load-bearing")
    assert_includes(kept.message, "load-bearing")
  end

  def test_send_with_literal_symbol_resolves_statically
    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        def entry(*args)
          send(:target, *args)
        end
      end
    RUBY

    report = check(source)
    assert_equal(1, report.issues.size)

    fixed = report.issues.first.suggestion.apply(source)
    assert_includes(fixed, "send(:target, *args, **kwargs)")
    assert_includes(arrival(fixed), "ARRIVAL_OK") if RUBY3
  end

  def test_double_splat_nil_callee_is_not_flagged
    source = <<~RUBY
      class Chain
        def target(*args, **nil)
          args
        end

        def entry(*args)
          target(*args)
        end
      end
    RUBY

    report = check(source)
    assert_empty(report.issues)
    assert_empty(report.suggestions)
  end

  def test_target_27_warns_about_deprecated_conversion
    report = check(BROKEN_CHAIN, target_version: "2.7")

    assert_equal(1, report.issues.size)
    issue = report.issues.first
    assert_includes(issue.message, "deprecated automatic Hash-to-keyword")

    fixed = issue.suggestion.apply(BROKEN_CHAIN)
    assert_includes(fixed, "def entry(*args, **kwargs)")
  end

  def test_target_26_accepts_automatic_conversion
    report = check(BROKEN_CHAIN, target_version: "2.6")

    assert_empty(report.issues)
    assert_empty(report.suggestions)
  end

  def test_multi_hop_chain_flags_every_losing_hop
    skip "requires Ruby >= 3.0 semantics" unless RUBY3

    source = <<~RUBY
      class Chain
        def target(*args, **kwargs)
          [args, kwargs]
        end

        def mid(*args)
          target(*args)
        end

        def entry(*args)
          mid(*args)
        end
      end
    RUBY

    assert_includes(arrival(source), "ARRIVAL_MISMATCH")

    report = check(source)
    assert_equal(2, report.issues.size)
    assert_equal(
      %w[Chain::entry Chain::mid],
      report.issues.map(&:method_name).sort
    )

    fixed = report.apply_suggestions(source)
    assert_includes(arrival(fixed), "ARRIVAL_OK")
  end

  def test_forward_all_requires_ruby_27
    report = check(FORWARD_ALL_CHAIN, target_version: "2.6")
    # Parsing `...` is a syntax error before 2.7, so there is nothing to
    # check; just ensure the checker targets 2.6 without crashing on
    # splat-only chains.
    assert_empty(report.issues)
  end
end
