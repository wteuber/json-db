# frozen_string_literal: true

module JsonDb
  module Associations
    # Describes one declared association. Kept as a value object so the target
    # class can be resolved *lazily* -- models frequently reference each other in
    # a cycle, and neither one may be loaded when the macro runs.
    class Reflection
      attr_reader :name, :macro, :owner, :class_name, :foreign_key, :dependent

      def initialize(name:, macro:, owner:, class_name:, foreign_key:, dependent: nil)
        @name = name.to_sym
        @macro = macro
        @owner = owner
        @class_name = class_name
        @foreign_key = foreign_key.to_sym
        @dependent = dependent
      end

      def collection?
        macro == :has_many
      end

      # Resolves +class_name+, preferring a constant in the owner's namespace
      # (so +Blog::Post belongs_to :author+ finds +Blog::Author+ before +Author+).
      def klass
        @klass ||= resolve_class
      end

      def inspect
        "#<#{self.class.name} #{macro} #{name} class_name=#{class_name} foreign_key=#{foreign_key}>"
      end

      private

      def resolve_class
        return class_name if class_name.is_a?(Class)

        candidates(class_name.to_s).each do |candidate|
          resolved = safe_constantize(candidate)
          return resolved if resolved.is_a?(Class)
        end

        raise AssociationError,
              "#{owner}##{name} points at #{class_name.inspect}, which could not be resolved to a class"
      end

      def candidates(name)
        namespace = owner.name.to_s.split("::")[0..-2]
        list = []
        list << "#{namespace.join('::')}::#{name}" unless namespace.empty?
        list << name
        list
      end

      def safe_constantize(name)
        ActiveSupport::Inflector.constantize(name)
      rescue NameError
        nil
      end
    end
  end
end
