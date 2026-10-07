# frozen_string_literal: true

# The same constant name is defined in two different namespaces. Which
# one a reference points to depends on the lexical scope of the
# reference site.
VALUE = "top-level VALUE"

class A
  VALUE = "A::VALUE"
end

