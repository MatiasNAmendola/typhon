module Typhon
  module AST

    class Body < ClosedScope
      def initialize(statement, line)
        @statement = statement
        @line = line
      end

      def bytecode(g)
        pos(g)

        if @statement.empty?
          g.push_nil
        else
          @statement.bytecode(g)
        end

        g.pop
        g.push_self
      end
    end

    class ModuleBody < Body
      def module?
        true
      end
    end

    class ModuleNode < ClosedScope
      attr_reader :parent #always nil for now.

      def bytecode(g)
        pos(g)

        g.push_const(:Typhon)
        g.find_const(:Environment)
        g.send(:get_python_module, 0)

        if (@doc)
          g.dup
          g.push_literal(:__doc__)
          g.push_literal(@doc)
          g.send(:py_set, 2)
          g.pop
        end

        @body = ModuleBody.new(@node, @line)
        attach_and_call(g, :__module_init__, false)
        g.ret # Actually want to return the module object to the enclosing scope.
      end
    end

    class ImportNode < Node
      def bytecode(g)
        pos(g)
        @names.each do |mod, name|
          name ||= mod.split(".").last
          g.push_const :Typhon
          g.find_const :CodeLoader
          g.push_literal mod
          g.push_self
          g.send :load_module, 2

          g.push_self
          g.swap
          g.push_literal name.to_sym
          g.swap
          g.send :py_set, 2
        end
      end
    end

  end
end
