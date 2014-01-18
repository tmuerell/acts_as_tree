require 'acts_as_tree/version'

module ActsAsTree

  if defined? Rails::Railtie
    require 'acts_as_tree/railtie'
  elsif defined? Rails::Initializer
    raise "acts_as_tree 1.0 is not compatible with Rails 2.3 or older"
  end

  def self.included(base)
    base.extend(ClassMethods)
  end

  # Specify this +acts_as+ extension if you want to model a tree structure
  # by providing a parent association and a children association. This
  # requires that you have a foreign key column, which by default is called
  # +parent_id+.
  #
  #   class Category < ActiveRecord::Base
  #     include ActsAsTree
  #
  #     acts_as_tree :order => "name"
  #   end
  #
  #   Example:
  #   root
  #    \_ child1
  #         \_ subchild1
  #         \_ subchild2
  #
  #   root      = Category.create("name" => "root")
  #   child1    = root.children.create("name" => "child1")
  #   subchild1 = child1.children.create("name" => "subchild1")
  #
  #   root.parent   # => nil
  #   child1.parent # => root
  #   root.children # => [child1]
  #   root.children.first.children.first # => subchild1
  #
  # In addition to the parent and children associations, the following
  # instance methods are added to the class after calling
  # <tt>acts_as_tree</tt>:
  # * <tt>siblings</tt> - Returns all the children of the parent, excluding
  #                       the current node (<tt>[subchild2]</tt> when called
  #                       on <tt>subchild1</tt>)
  # * <tt>self_and_siblings</tt> - Returns all the children of the parent,
  #                                including the current node (<tt>[subchild1, subchild2]</tt>
  #                                when called on <tt>subchild1</tt>)
  # * <tt>ancestors</tt> - Returns all the ancestors of the current node
  #                        (<tt>[child1, root]</tt> when called on <tt>subchild2</tt>)
  # * <tt>root</tt> - Returns the root of the current node (<tt>root</tt>
  #                   when called on <tt>subchild2</tt>)
  module ClassMethods
    # Configuration options are:
    #
    # * <tt>foreign_key</tt> - specifies the column name to use for tracking
    #                          of the tree (default: +parent_id+)
    # * <tt>order</tt> - makes it possible to sort the children according to
    #                    this SQL snippet.
    # * <tt>counter_cache</tt> - keeps a count in a +children_count+ column
    #                            if set to +true+ (default: +false+).
    def acts_as_tree(options = {})
      configuration = {
        foreign_key:   "parent_id",
        order:         nil,
        counter_cache: nil,
        dependent:     :destroy
      }

      configuration.update(options) if options.is_a?(Hash)

      belongs_to :parent, class_name:    name,
        foreign_key:   configuration[:foreign_key],
        counter_cache: configuration[:counter_cache],
        inverse_of:    :children

      if ActiveRecord::VERSION::MAJOR >= 4
        has_many :children, lambda { order configuration[:order] },
          class_name:  name,
          foreign_key: configuration[:foreign_key],
          dependent:   configuration[:dependent],
          inverse_of:  :parent
      else
        has_many :children, class_name:  name,
          foreign_key: configuration[:foreign_key],
          order:       configuration[:order],
          dependent:   configuration[:dependent],
          inverse_of:  :parent
      end

      class_eval <<-EOV
        include ActsAsTree::InstanceMethods

        after_update :update_parents_counter_cache

        def self.roots
          order_option = %Q{#{configuration.fetch :order, "nil"}}
          where(:#{configuration[:foreign_key]} => nil).order(order_option)
        end

        def self.root
          self.roots.first
        end
      EOV
    end

  end

  module Presentation
    # show records in a tree view
    # Example:
    # root
    #  |_ child1
    #  |    |_ subchild1
    #  |    |_ subchild2
    #  |_ child2
    #       |_ subchild3
    #       |_ subchild4
    #
    def tree_view(label_method = :to_s,  node = nil, level = -1)
      if node.nil?
        puts "root"
        nodes = roots
      else
        label = "|_ #{node.send(label_method)}"
        if level == 0
          puts " #{label}"
        else
          puts " |#{"    "*level}#{label}"
        end
        nodes = node.children
      end
      nodes.each do |child|
        tree_view(label_method, child, level+1)
      end
    end

  end

  module InstanceMethods
    # Returns list of ancestors, starting from parent until root.
    #
    #   subchild1.ancestors # => [child1, root]
    def ancestors
      node, nodes = self, []
      nodes << node = node.parent while node.parent
      nodes
    end

    # Returns list of descendants, starting from current node, not including current node.
    #
    #   root.descendants # => [child1, child2, subchild1, subchild2, subchild3, subchild4]
    def descendants
      children.each_with_object(children.to_a) {|child, arr|
        arr.concat child.descendants
      }.uniq
    end

    # Returns list of descendants, starting from current node, including current node.
    #
    #   root.self_and_descendants # => [root, child1, child2, subchild1, subchild2, subchild3, subchild4]
    def self_and_descendants
      [self] + descendants
    end

    # Returns the root node of the tree.
    def root
      node = self
      node = node.parent while node.parent
      node
    end

    # Returns all siblings of the current node.
    #
    #   subchild1.siblings # => [subchild2]
    def siblings
      self_and_siblings - [self]
    end

    # Returns all siblings and a reference to the current node.
    #
    #   subchild1.self_and_siblings # => [subchild1, subchild2]
    def self_and_siblings
      parent ? parent.children : self.class.roots
    end

    # Returns children (without subchildren) and current node itself.
    #
    #   root.self_and_children # => [root, child1]
    def self_and_children
      [self] + self.children
    end

    # Returns ancestors and current node itself.
    #
    #   subchild1.self_and_ancestors # => [subchild1, child1, root]
    def self_and_ancestors
      [self] + self.ancestors
    end

    # Returns true if node has no parent, false otherwise
    #
    #   subchild1.root? # => false
    #   root.root?      # => true
    def root?
      parent.nil?
    end

    # Returns true if node has no children, false otherwise
    #
    #   subchild1.leaf? # => true
    #   child1.leaf?    # => false
    def leaf?
      children.count == 0
    end

    private

    def update_parents_counter_cache
      if self.respond_to?(:children_count) && parent_id_changed?
        self.class.decrement_counter(:children_count, parent_id_was)
        self.class.increment_counter(:children_count, parent_id)
      end
    end
  end
end

# Deprecating the following code in the future.
require 'acts_as_tree/active_record/acts/tree'
