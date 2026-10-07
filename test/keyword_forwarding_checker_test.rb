# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class KeywordForwardingCheckerTest < Minitest::Test
    def test_adds_missing_keyword_splat_and_proves_arrival
      source = <<~RUBY
        def terminal(positional, keyword:, &block)
          [positional, keyword, block.call]
        end

        def proxy(positional, *args, **kwargs, &block)
          terminal(positional, *args, &block)
        end

        result = proxy(7, keyword: 8) { 9 }
        Marshal.dump(result, STDOUT)
      RUBY

      checker = KeywordForwardingChecker.new(target_ruby_version: "3.3.0")
      findings = checker.check(source)
      finding =
        findings.find { |item| item.status == :keyword_arguments_dropped }

      assert finding
      assert_equal "kwargs",
                   finding
                     .roles
                     .keys
                     .find { |name| name.start_with?("**") }
                     &.delete_prefix("**")

      migrated = checker.rewrite(source)
      assert_includes migrated, "terminal(positional, *args, **kwargs, &block)"
      assert SyntaxTree.parse(migrated)

      before = run_source(source)
      after = run_source(migrated)

      refute_predicate before, :success?
      assert_includes before.stderr, "missing keyword: :keyword"
      assert_predicate after, :success?
      assert_equal [7, 8, 9], Marshal.load(after.stdout)
    end

    def test_restores_ruby2_keywords_through_unmarked_chain
      source = <<~RUBY
        def terminal(keyword:)
          keyword
        end

        ruby2_keywords def first(*args)
          second(*args)
        end

        def second(*args)
          third(*args)
        end

        def third(*args)
          terminal(*args)
        end

        Marshal.dump(first(keyword: 42), STDOUT)
      RUBY

      checker = KeywordForwardingChecker.new(target_ruby_version: "3.3.0")
      findings = checker.check(source)
      marker_reasons = findings.flat_map(&:patches).map(&:reason).uniq
      marker_findings = findings.select { |finding| finding.patches.any? }

      assert_equal [
                     "mark second with ruby2_keywords",
                     "mark third with ruby2_keywords"
                   ].sort,
                   marker_reasons.sort

      assert_includes marker_findings.flat_map(&:chain).map(&:first), "first"

      migrated = checker.rewrite(source)
      assert_match(/ruby2_keywords def second/, migrated)
      assert_match(/ruby2_keywords def third/, migrated)
      assert SyntaxTree.parse(migrated)

      before = run_source(source)
      after = run_source(migrated)

      refute_predicate before, :success?
      assert_predicate after, :success?
      assert_equal 42, Marshal.load(after.stdout)
    end

    def test_forward_annotation_is_safe_and_blocks_are_forwarded
      source = <<~RUBY
        def terminal(positional:, &block)
          [positional, block.call]
        end

        def proxy(...)
          terminal(...)
        end

        Marshal.dump(proxy(positional: 3) { 4 }, STDOUT)
      RUBY

      findings =
        KeywordForwardingChecker.check(source, target_ruby_version: "3.3.0")

      assert_equal [:forwards_keywords], findings.map(&:status).uniq
      assert_equal "...", findings.first.roles.keys.first
      assert_empty findings.flat_map(&:patches)
      assert_equal [3, 4], Marshal.load(run_source(source).stdout)
    end

    def test_dynamic_dispatch_and_unknown_receivers_keep_dynamic_explanations
      source = <<~RUBY
        ruby2_keywords def dynamic(*args)
          public_send(:terminal, *args)
        end

        def explicit_receiver(*args)
          object.terminal(*args)
        end
      RUBY

      findings =
        KeywordForwardingChecker.check(source, target_ruby_version: "3.3.0")

      assert_equal %i[dynamic_dispatch unknown_callee], findings.map(&:status)
      assert_empty findings.flat_map(&:patches)
      assert_includes findings.first.explanation, "dynamically"
      assert_includes findings.last.explanation, "explicit receiver"
    end

    def test_unknown_callee_local_keyword_patch_does_not_claim_arrival
      source = <<~RUBY
        def proxy(*args, **kwargs)
          object.terminal(*args)
        end
      RUBY

      findings =
        KeywordForwardingChecker.check(source, target_ruby_version: "3.3.0")

      assert_equal [:keyword_arguments_locally_added], findings.map(&:status)
      assert_equal [", **kwargs"],
                   findings.flat_map(&:patches).map(&:replacement)
      assert_includes findings.first.explanation, "not statically resolved"
    end

    def test_targets_before_ruby2_keywords_keep_chains_explained
      source = <<~RUBY
        def terminal(keyword:)
          keyword
        end

        def proxy(*args)
          terminal(*args)
        end
      RUBY

      findings =
        KeywordForwardingChecker.check(source, target_ruby_version: "2.6.0")

      assert_equal [:implicit_keyword_conversion], findings.map(&:status)
      assert_empty findings.flat_map(&:patches)
    end

    def test_positional_hash_forwarding_is_not_reported_as_keyword_loss
      source = <<~RUBY
        def terminal(options)
          options.fetch(:keyword)
        end

        def proxy(options = {})
          terminal(options)
        end
      RUBY

      assert_empty KeywordForwardingChecker.check(
                     source,
                     target_ruby_version: "3.3.0"
                   )
    end

    def test_marked_dynamic_dispatch_is_explained_but_not_rewritten
      source = <<~RUBY
        def terminal(keyword:)
          keyword
        end

        ruby2_keywords def proxy(*args)
          send(:terminal, *args)
        end

        Marshal.dump(proxy(keyword: 11), STDOUT)
      RUBY

      findings =
        KeywordForwardingChecker.check(source, target_ruby_version: "3.3.0")

      assert_equal [:dynamic_dispatch], findings.map(&:status)
      assert_empty findings.flat_map(&:patches)
      assert_includes findings.first.roles.values.flatten.join,
                      "preserves the ruby2_keywords marker"
      assert_equal source,
                   KeywordForwardingChecker.rewrite(
                     source,
                     target_ruby_version: "3.3.0"
                   )
      assert_equal 11, Marshal.load(run_source(source).stdout)
    end

    def test_observed_arguments_array_blocks_ruby2_keywords_suggestion
      source = <<~RUBY
        def terminal(keyword:)
          keyword
        end

        def proxy(*args)
          observed = args
          terminal(*args)
        end

        Marshal.dump(proxy(keyword: 12), STDOUT)
      RUBY

      findings =
        KeywordForwardingChecker.check(source, target_ruby_version: "3.3.0")

      assert_equal [:keyword_arguments_unprovable], findings.map(&:status)
      assert_empty findings.flat_map(&:patches)
      assert_equal source,
                   KeywordForwardingChecker.rewrite(
                     source,
                     target_ruby_version: "3.3.0"
                   )

      result = run_source(source)
      refute_predicate result, :success?
      assert_includes result.stderr, "required keyword"
    end

    def test_explicit_keywords_can_transition_into_marked_legacy_chain
      source = <<~RUBY
        def terminal(keyword:)
          keyword
        end

        def inner(*args)
          terminal(*args)
        end

        def middle(*args, **kwargs)
          inner(*args, **kwargs)
        end

        Marshal.dump(middle(keyword: 31), STDOUT)
      RUBY

      checker = KeywordForwardingChecker.new(target_ruby_version: "3.3.0")
      findings = checker.check(source)
      marker_patches =
        findings
          .flat_map(&:patches)
          .uniq(&:reason)
          .select { |patch| patch.reason == "mark inner with ruby2_keywords" }

      assert_equal 1, marker_patches.length

      migrated = checker.rewrite(source)
      assert_match(/ruby2_keywords def inner/, migrated)
      assert SyntaxTree.parse(migrated)

      before = run_source(source)
      after = run_source(migrated)

      refute_predicate before, :success?
      assert_predicate after, :success?
      assert_equal 31, Marshal.load(after.stdout)
    end

    private

    Result =
      Struct.new(:stdout, :stderr, :status, keyword_init: true) do
        def success?
          status.success?
        end
      end

    def run_source(source)
      Dir.mktmpdir do |directory|
        filepath = File.join(directory, "example.rb")
        File.write(filepath, source)
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, filepath)
        Result.new(stdout: stdout, stderr: stderr, status: status)
      end
    end
  end
end
