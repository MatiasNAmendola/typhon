module Typhon
  class AST

    Nodes = Hash.new

    # Converts a ruby sexp (array literals) into Typhon AST
    def self.from_sexp(sexp)
      return nil if sexp.nil? || sexp.empty?
      name = :"#{sexp.first}Node"
      type = Nodes[name]
      raise "Unknown sexp type: #{name}" unless type
      convert = lambda do |e|
        if e.kind_of?(Array) && e.first.kind_of?(Symbol)
          from_sexp(e)
        elsif e.kind_of?(Array)
          e.map(&convert)
        else
          e
        end
      end
      args = sexp[1..-1].map(&convert)
      type.new(*args)
    end

    def self.node(name, *attributes)
      name_sym = :"#{name}Node"
      begin
        cls = self.const_get(name_sym)
      rescue NameError
      end
      cls = cls || ::Class.new(BlowUpNode)
      
      self.const_set(name_sym, cls)
      Nodes[name_sym] = cls
      names = ['line'] + attributes
      attrs = names.map { |a| '@' + a }

      cls.attr_accessor *names
      cls.module_eval <<-INIT
        def initialize(#{names.join(', ')})
          #{attrs.join(', ')} = #{names.join(', ')}
        end
      INIT
    end

    Node = Rubinius::AST::Node
    ClosedScope = Rubinius::AST::ClosedScope
    
    class BlowUpNode < Node
      def bytecode(g)
        pos(g)
        raise "Unimplemented bytecode for #{self.class}!"
      end
    end

    class DiscardNode < Node
      def bytecode(g)
        pos(g)
        
        @expr.bytecode(g)
        g.pop # ignore whatever it did.
      end
    end
    
    class ConstNode < Node
      def bytecode(g)
        pos(g)
        
        g.push_literal(@value)
      end
    end
    
    class ListNode < Node
      def bytecode(g)
        pos(g)
        
        @nodes.each do |node|
          node.bytecode(g)
        end
        g.make_array(@nodes.size)
      end
    end
    
    class TupleNode < Node
      def bytecode(g)
        pos(g)
        
        @nodes.each do |node|
          node.bytecode(g)
        end
        g.make_array(@nodes.size)
        # TODO: This needs to actually make a frozen list of some sort. Tuples are immutable.
      end
    end
    
    class DictNode < Node
      def bytecode(g)
        g.push_cpath_top
        g.find_const :Hash
        g.push @items.size
        g.send :new_from_literal, 1
        
        @items.each do |node|
          g.dup
          key, value = node
          key.bytecode(g)
          value.bytecode(g)
          g.send(:[]=, 2)
          g.pop
        end
        # ...
      end
    end
    
    class PrintnlNode < Node
      def bytecode(g)
        pos(g)
        
        g.push_self
        @nodes.each do |node|
          node.bytecode(g)
        end
        g.send :__print__, @nodes.count
      end
    end
    
    class Body < ClosedScope
      def initialize(statement, line)
        @statement = statement
        @line = line
      end
      
      def bytecode(g)
        pos(g)
        
#        g.definition_line(@line)
        @statement.bytecode(g)
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
        
        g.push_const(:PythonModule)
        # TODO: later this needs to take into account how the code was included
        # In ruby the module name is internal to the system, but in python it comes
        # from the import declaration that included it.
        g.push_literal(nil)
        g.push_literal('__main__')
        g.push_literal(@doc)
        g.send(:new, 3)
        
        @body = ModuleBody.new(@node, @line)
        attach_and_call(g, :__module_init__, true)
        g.ret # Actually want to return the module object to the enclosing scope.
      end
    end
    
    class StmtNode < ClosedScope
      def bytecode(g)
        pos(g)
        @nodes.each do |node|
          node.bytecode(g)
        end
      end
    end
    
    class FunctionNode < ClosedScope
      include Compiler::LocalVariables
      
      attr_reader :parent
      
      class Arguments
        attr_reader :argnames, :defaults
        def initialize(argnames, defaults)
          @argnames = argnames
          @defaults = defaults
        end
        
        def required_args
          @argnames.length - @defaults.length
        end
        def total_args
          @argnames.length
        end
        def splat_index
          nil
        end
        
        def required_names
          @argnames[0..@argnames.count-@defaults.count]
        end
        
        def default_names
          if (defaults.count > 0)
            @argnames[-defaults.count..-1]
          else
            []
          end
        end
        
        def bytecode(g)
          return if (total_args == 0)
          
          # get the args into an array on the stack
          g.cast_for_splat_block_arg
          
          # if the function takes no args we need no bytecode
          args_done = g.new_label
          
          # because we treat all methods as blocks to capture closure state,
          # we need to pull in arguments manually.
          args_present = g.new_label
          
          # if the last arg was passed we're already good.
          g.passed_arg(@argnames.count - 1)
          g.git(args_present)
          
          # if the last required arg isn't passed, we have to blow up
          insufficient_args = g.new_label
          g.passed_arg(@argnames.count - @defaults.count - 1)
          g.gif(insufficient_args)
          
          # push missing default arguments until we hit one that's present.
          # note: this is probably not the most efficient way to do it, but it
          # at least avoids branching too much.
          @defaults.reverse.each_with_index do |default, i|
            g.passed_arg(total_args - i - 1)
            g.git(args_present)
            
            g.push_literal(-i - 1)
            default.bytecode(g)
            g.send(:insert, 2)
          end

          args_present.set!
          # once we're here we know we have all arguments on the stack
          @argnames.each do |name|
            var = g.state.scope.new_local(name.to_sym)
            g.shift_array
            g.set_local(var.reference.slot)
            g.pop
          end
          g.goto(args_done)
          
          insufficient_args.set!
          
          g.push_true #TODO: make this a real exception object.
          g.raise_exc
          
          args_done.set!
          g.pop # clear the array off the stack.
        end
      end
      
      def compile_body(g)
        meth = new_generator(g, @name.to_sym, @arguments)
        
        state = g.state
        @parent = state.scope
        meth.push_state self
        meth.state.push_super state.super
        meth.state.push_eval state.eval
#        meth.definition_line(@line)

        meth.state.push_name @name.to_sym

        @arguments.bytecode(meth)
        @code.bytecode(meth)

        meth.state.pop_name

        meth.local_count = local_count
        meth.local_names = local_names

        meth.ret
        meth.close
        meth.pop_state

        return meth
      end
      
      def bytecode(g)
        pos(g)
        
        @arguments = Arguments.new(@argnames,@defaults)
        
        g.push_self
        g.push_literal @name.to_sym
        g.create_block compile_body(g)
        g.allow_private
        g.send_with_block(:__define_method__, 1)

        # to add an actual method to a class, it actually goes like:
        #g.push_variables
        #g.send :method_visibility, 0
        #g.send :add_defn_method, 4
      end
    end
    
    class CallFuncNode < Node
      def bytecode(g)
        pos(g)
        
        g.push_self
        @args.each do |arg|
          arg.bytecode(g)
        end
        # TODO: deal with splats and such as well.
        g.send @node.name.to_sym, @args.count
      end
    end
    
    class VarNode < Node
      # Finds a normal variable, doesn't go into BuiltIn, though.
      def find_normal_var(g, name)
        name = name.to_sym
        scope = g.state.scope
        # First try to find it in a function scope.
        scope_depth = 0
        while (scope.kind_of?(FunctionNode) || scope.kind_of?(ModuleNode))
          var = scope.variables[name]
          if (var)
            yield var.reference, scope_depth
            return
          end
          scope_depth += 1
          scope = scope.parent
        end
        # TODO: Then look in module scope.
      end
    end
    
    class NameNode < VarNode
      def bytecode(g)
        pos(g)
        find_normal_var(g, @name) do |ref, depth|
          if (depth > 0)
            g.push_local_depth(depth, ref.slot)
          else
            g.push_local(ref.slot)
          end
          return
        end
        
        # TODO: Figure out Builtins.
        #raise SyntaxError, "BOOM"
      end
    end
    
    class AssignNode < VarNode
      def bytecode(g)
        pos(g)

        # no matter what, we want the RHS on the stack.
        @expr.bytecode(g)

        # TODO: This is completely biased towards single assignment. Everything
        # else will probably fail spectacularly.
        name = @nodes[0].name.to_sym

        find_normal_var(g, name) do |ref, depth|
          if (depth > 0)
            g.set_local_depth(depth, ref.slot)
          else
            g.set_local(ref.slot)
          end
          return
        end
        # if we're here we didn't find anywhere to set it, so create it.
        g.set_local(g.state.scope.new_local(name).reference.slot)
      end
    end   
    
    # Nodes classes. Read from node.py
    nodes = eval File.read(File.expand_path("../../../bin/node.py", File.dirname(__FILE__)))
    nodes.each { |n| node n.first, *n.last }
  end
end
