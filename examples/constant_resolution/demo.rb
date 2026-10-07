# frozen_string_literal: true

# Demonstrates SyntaxTree::Index::ConstantResolver on the small files
# in this directory. The same constant name (VALUE) resolves to
# different definitions depending on whether the class was opened
# with the nested or the compact definition style.
#
# Run from the repository root with:
#
#     ruby -Ilib examples/constant_resolution/demo.rb

require "syntax_tree"

resolver = SyntaxTree::Index::ConstantResolver.new
files = Dir[File.join(__dir__, "*.rb")].sort - [File.expand_path(__FILE__)]
files.each { |file| resolver.index_file(file) }

resolver.references.each do |reference|
  puts resolver.resolve(reference)
  puts
end

