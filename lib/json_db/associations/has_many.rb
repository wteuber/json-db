# frozen_string_literal: true

module JsonDb
  module Associations
    # Adds the +has_many+ macro: the *other* side stores the foreign key.
    module HasMany
      module ClassMethods
        # Declares a one-to-many association. The reader returns a lazy
        # {Query::Relation}, so +user.tasks.where(done: false).count+ never
        # materialises the full collection.
        #
        #   class User < JsonDb::Base
        #     has_many :tasks, dependent: :destroy
        #   end
        #
        # @param name [Symbol] association name, e.g. +:tasks+
        # @param class_name [String, Class, nil] defaults to +name.singularize.camelize+
        # @param foreign_key [Symbol, nil] defaults to +:"#{model_name.element}_id"+, i.e.
        #   the demodulized model name (+Blog::Author+ -> +:author_id+)
        # @param dependent [:destroy, :nullify, nil] what happens to children on destroy
        # @return [Reflection]
        def has_many(name, class_name: nil, foreign_key: nil, dependent: nil)
          name = name.to_sym
          key = (foreign_key || :"#{model_name.element}_id").to_sym

          reflection = add_reflection(
            Reflection.new(
              name: name, macro: :has_many, owner: self,
              class_name: class_name || name.to_s.singularize.camelize,
              foreign_key: key, dependent: dependent
            )
          )

          define_method(name) do
            target = self.class.reflect_on(name)
            # An unsaved owner has a nil id, and where(foreign_key => nil) would
            # match every child that belongs to nobody at all.
            next target.klass.all.none if id.nil?

            target.klass.where(target.foreign_key => id)
          end

          define_dependency_callback(reflection)

          reflection
        end

        private

        # Children are cleaned up *before* the parent file disappears, so an
        # interrupted destroy leaves the parent behind to retry with rather than
        # orphaning rows that nothing points at any more. Each callback bails on
        # a nil id for the same reason the reader does: it would match every
        # unowned child and cascade over records this owner never had.
        def define_dependency_callback(reflection)
          case reflection.dependent
          when nil then nil
          when :destroy
            before_destroy do
              next if id.nil?

              self.class.reflect_on(reflection.name).klass.where(reflection.foreign_key => id).each(&:destroy)
            end
          when :nullify
            before_destroy do
              next if id.nil?

              self.class.reflect_on(reflection.name).klass
                  .where(reflection.foreign_key => id)
                  .each { |child| child.update!(reflection.foreign_key => nil) }
            end
          when :restrict
            before_destroy do
              next if id.nil?

              if self.class.reflect_on(reflection.name).klass.where(reflection.foreign_key => id).exists?
                errors.add(:base, "cannot destroy #{self.class.name} while #{reflection.name} still exist")
                throw :abort
              end
            end
          else
            raise ConfigurationError,
                  "Unknown :dependent option #{reflection.dependent.inspect} " \
                  "(expected :destroy, :nullify or :restrict)"
          end
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end
    end
  end
end
