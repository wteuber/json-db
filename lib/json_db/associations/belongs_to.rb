# frozen_string_literal: true

module JsonDb
  module Associations
    # Adds the +belongs_to+ macro: the declaring record stores the foreign key.
    module BelongsTo
      module ClassMethods
        # Declares a many-to-one association.
        #
        #   class Task < JsonDb::Base
        #     belongs_to :user
        #   end
        #
        #   task.user       #=> User or nil
        #   task.user = bob # writes task.user_id
        #
        # @param name [Symbol] association name
        # @param class_name [String, Class, nil] target class; defaults to +name.camelize+
        # @param foreign_key [Symbol, nil] defaults to +:"#{name}_id"+
        # @param optional [Boolean] when false, a presence validation is added on the key
        # @param type [Symbol] attribute type used when the foreign key is not declared yet
        # @return [Reflection]
        def belongs_to(name, class_name: nil, foreign_key: nil, optional: true, type: :string)
          name = name.to_sym
          key = (foreign_key || :"#{name}_id").to_sym

          attribute(key, type) unless attribute_types.key?(key.to_s)

          reflection = add_reflection(
            Reflection.new(
              name: name, macro: :belongs_to, owner: self,
              class_name: class_name || name.to_s.camelize, foreign_key: key
            )
          )

          define_method(name) do
            association_cache.fetch(name) do
              target = self.class.reflect_on(name)
              value = self[target.foreign_key]
              # find_by would build a relation, and the primary key is never an
              # indexed attribute, so it would read every document in the target
              # collection to answer a single-document lookup.
              association_cache[name] = value.nil? ? nil : target.klass.find_by_id(value)
            end
          end

          define_method(:"#{name}=") do |record|
            self[key] = record&.id
            association_cache[name] = record
          end

          define_method(:"reload_#{name}") do
            association_cache.delete(name)
            public_send(name)
          end

          validates(key, presence: true) unless optional

          reflection
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end
    end
  end
end
