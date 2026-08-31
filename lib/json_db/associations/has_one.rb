# frozen_string_literal: true

module JsonDb
  module Associations
    # Adds the +has_one+ macro: like {HasMany}, but the reader returns a single
    # record (or nil) instead of a relation.
    module HasOne
      module ClassMethods
        # @param name [Symbol] association name, e.g. +:profile+
        # @param class_name [String, Class, nil] defaults to +name.camelize+
        # @param foreign_key [Symbol, nil] defaults to +:"#{model_name.element}_id"+, i.e.
        #   the demodulized model name (+Blog::Author+ -> +:author_id+)
        # @param dependent [:destroy, :nullify, nil]
        # @return [Reflection]
        def has_one(name, class_name: nil, foreign_key: nil, dependent: nil)
          name = name.to_sym
          key = (foreign_key || :"#{model_name.element}_id").to_sym

          reflection = add_reflection(
            Reflection.new(
              name: name, macro: :has_one, owner: self,
              class_name: class_name || name.to_s.camelize,
              foreign_key: key, dependent: dependent
            )
          )

          define_method(name) do
            association_cache.fetch(name) do
              target = self.class.reflect_on(name)
              # A nil id would match every child that belongs to nobody at all.
              association_cache[name] =
                id.nil? ? nil : target.klass.where(target.foreign_key => id).first
            end
          end

          # The foreign key lives on the child, so assigning has to reach the
          # child's document for the assignment to survive. A persisted owner can
          # write it immediately; a new one has no id to write yet, so the child
          # is stamped and saved by the after_save below instead.
          define_method(:"#{name}=") do |record|
            association_cache[name] = record
            next record if record.nil?

            record[key] = id
            record.save if persisted?
            record
          end

          after_save do
            record = association_cache[name]
            next if record.nil? || record[key] == id

            record[key] = id
            record.save
          end

          define_method(:"reload_#{name}") do
            association_cache.delete(name)
            public_send(name)
          end

          define_dependency_callback(reflection)

          reflection
        end
      end

      def self.included(base)
        base.extend(ClassMethods)
      end
    end
  end
end
