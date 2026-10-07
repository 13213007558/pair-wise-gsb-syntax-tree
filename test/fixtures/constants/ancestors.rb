module Included
  VALUE = :included
end

class Parent
  VALUE = :parent
end

class Child < Parent
  include Included
  VALUE
end
