require 'bigdecimal'
require 'securerandom'
require 'yaml'

# encoding: utf-8
module Dynamoid

  # Persistence is responsible for dumping objects to and marshalling objects from the datastore. It tries to reserialize
  # values to be of the same type as when they were passed in, based on the fields in the class.
  module Persistence
    extend ActiveSupport::Concern

    attr_accessor :new_record
    alias :new_record? :new_record

    module ClassMethods

      def table_name
        @table_name ||= "#{Dynamoid::Config.namespace}_#{options[:name] || base_class.name.split('::').last.downcase.pluralize}"
      end

      # Creates a table.
      #
      # @param [Hash] options options to pass for table creation
      # @option options [Symbol] :id the id field for the table
      # @option options [Symbol] :table_name the actual name for the table
      # @option options [Integer] :read_capacity set the read capacity for the table; does not work on existing tables
      # @option options [Integer] :write_capacity set the write capacity for the table; does not work on existing tables
      # @option options [Hash] {range_key => :type} a hash of the name of the range key and a symbol of its type
      # @option options [Symbol] :hash_key_type the dynamo type of the hash key (:string or :number)
      # @since 0.4.0
      def create_table(options = {})
        if self.range_key
          range_key_hash = { range_key => dynamo_type(attributes[range_key][:type]) }
        else
          range_key_hash = nil
        end
        options = {
          :id => self.hash_key,
          :table_name => self.table_name,
          :write_capacity => self.write_capacity,
          :read_capacity => self.read_capacity,
          :range_key => range_key_hash,
          :hash_key_type => dynamo_type(attributes[self.hash_key][:type]),
          :local_secondary_indexes => self.local_secondary_indexes.values,
          :global_secondary_indexes => self.global_secondary_indexes.values
        }.merge(options)

        Dynamoid.adapter.create_table(options[:table_name], options[:id], options)
      end

      # Deletes the table for the model
      def delete_table
        Dynamoid.adapter.delete_table(self.table_name)
      end

      def from_database(attrs = {})
        clazz = attrs[:type] ? obj = attrs[:type].constantize : self
        clazz.new(attrs).tap { |r| r.new_record = false }
      end

      # Undump an object into a hash, converting each type from a string representation of itself into the type specified by the field.
      #
      # @since 0.2.0
      def undump(incoming = nil)
        incoming = (incoming || {}).symbolize_keys
        Hash.new.tap do |hash|
          self.attributes.each do |attribute, options|
            hash[attribute] = undump_field(incoming[attribute], options)
          end
          incoming.each {|attribute, value| hash[attribute] = value unless hash.has_key? attribute }
        end
      end

      # Undump a string value for a given type.
      #
      # @since 0.2.0
      def undump_field(value, options)
        if (field_class = options[:type]).is_a?(Class)
          raise 'Dynamoid class-type fields do not support default values' if options[:default]

          if field_class.respond_to?(:dynamoid_load)
            field_class.dynamoid_load(value)
          end
        elsif options[:type] == :serialized
          if value.is_a?(String)
            options[:serializer] ? options[:serializer].load(value) : YAML.load(value)
          else
            value
          end
        else
          if value.nil? && (default_value = options[:default])
            value = default_value.respond_to?(:call) ? default_value.call : default_value
          end

          if !value.nil?
            case options[:type]
              when :string
                value.to_s
              when :integer
                Integer(value)
              when :number
                BigDecimal.new(value.to_s)
              when :array
                value.to_a
              when :hash
                value
              when :set
                Set.new(value)
              when :datetime
                if value.is_a?(Date) || value.is_a?(DateTime) || value.is_a?(Time)
                  value
                else
                  Time.at(value).to_datetime
                end
              when :boolean
                # persisted as 't', but because undump is called during initialize it can come in as true
                if value == 't' || value == true
                  true
                elsif value == 'f' || value == false
                  false
                else
                  raise ArgumentError, "Boolean column neither true nor false"
                end
              else
                raise ArgumentError, "Unknown type #{options[:type]}"
            end
          end
        end
      end

      def dynamo_type(type)
        if type.is_a?(Class)
          type.respond_to?(:dynamoid_field_type) ? type.dynamoid_field_type : :string
        else
          case type
            when :integer, :number, :datetime
              :number
            when :string, :serialized
              :string
            else
              raise 'unknown type'
          end
        end
      end

      # Do not use this on production. It is easier to recreate a table
      # rather than do this. This is for testing only
      # @param opts
      # @option opts [Boolean] :skip_lock_check - skips checking the lock version
      def destroy_all(opts = {})
        batch_size = opts[:batch_size] || 100
        self.eval_limit(batch_size).all.each {|i| i.destroy(opts)}
      end
    end

    # Set updated_at and any passed in field to current DateTime. Useful for things like last_login_at, etc.
    #
    def touch(name = nil)
      now = DateTime.now
      self.updated_at = now
      attributes[name] = now if name
      save
    end

    # Is this object persisted in the datastore? Required for some ActiveModel integration stuff.
    #
    # @since 0.2.0
    def persisted?
      !new_record?
    end

    # Run the callbacks and then persist this object in the datastore.
    #
    # @since 0.2.0
    def save(options = {})
      self.class.create_table

      if new_record?
        conditions = { :unless_exists => [self.class.hash_key]}
        conditions[:unless_exists] << range_key if(range_key)

        run_callbacks(:create) { persist(conditions) }
      else
        persist
      end

      self
    end

    #
    # update!() will increment the lock_version if the table has the column, but will not check it. Thus, a concurrent save will
    # never cause an update! to fail, but an update! may cause a concurrent save to fail.
    #
    #
    def update!(conditions = {}, &block)
      run_callbacks(:update) do
        options = range_key ? {:range_key => dump_field(self.read_attribute(range_key), self.class.attributes[range_key])} : {}

        begin
          new_attrs = Dynamoid.adapter.update_item(self.class.table_name, self.hash_key, options.merge(:conditions => conditions)) do |t|
            if(self.class.attributes[:lock_version])
              t.add(lock_version: 1)
            end

            yield t
          end
          load(new_attrs)
        rescue Dynamoid::Errors::ConditionalCheckFailedException
          raise Dynamoid::Errors::StaleObjectError.new(self, 'update')
        end
      end
    end

    def update(conditions = {}, &block)
      update!(conditions, &block)
      true
    rescue Dynamoid::Errors::StaleObjectError
      false
    end

    # Delete this object, but only after running callbacks for it.
    # @param opts
    # @option opts [Boolean] :skip_lock_check - skips checking the lock version
    # @since 0.2.0
    def destroy(opts = {})
      ret = run_callbacks(:destroy) do
        self.delete(opts)
      end
      (ret == false) ? false : self
    end

    # @param opts
    # @option opts [Boolean] :skip_lock_check - skips checking the lock version
    def destroy!(opts = {})
      destroy(opts) || raise(Dynamoid::Errors::RecordNotDestroyed.new(self))
    end

    # Delete this object from the datastore.
    #
    # @since 0.2.0
    def delete(opts = {})
      options = range_key ? {:range_key => dump_field(self.read_attribute(range_key), self.class.attributes[range_key])} : {}

      # Add an optimistic locking check if the lock_version column exists
      unless opts[:skip_lock_check] == true
        if(self.class.attributes[:lock_version])
          conditions = {:if => {}}
          conditions[:if][:lock_version] =
            if changes[:lock_version].nil?
              self.lock_version
            else
              changes[:lock_version][0]
            end
          options[:conditions] = conditions
        end
      end
      Dynamoid.adapter.delete(self.class.table_name, self.hash_key, options)
    rescue Dynamoid::Errors::ConditionalCheckFailedException
      raise Dynamoid::Errors::StaleObjectError.new(self, 'delete')
    end

    # Dump this object's attributes into hash form, fit to be persisted into the datastore.
    #
    # @since 0.2.0
    def dump
      Hash.new.tap do |hash|
        self.class.attributes.each do |attribute, options|
          hash[attribute] = dump_field(self.read_attribute(attribute), options)
        end
      end
    end

    private

    # Determine how to dump this field. Given a value, it'll determine how to turn it into a value that can be
    # persisted into the datastore.
    #
    # @since 0.2.0
    def dump_field(value, options)
      if (field_class = options[:type]).is_a?(Class)
        if value.respond_to?(:dynamoid_dump)
          value.dynamoid_dump
        elsif field_class.respond_to?(:dynamoid_dump)
          field_class.dynamoid_dump(value)
        else
          raise ArgumentError, "Neither #{field_class} nor #{value} support serialization for Dynamoid."
        end
      else
        case options[:type]
          when :string
            !value.nil? ? value.to_s : nil
          when :integer
            !value.nil? ? Integer(value) : nil
          when :number
            !value.nil? ? value : nil
          when :set
            !value.nil? ? dump_object(Set.new(value)) : nil
          when :array
            !value.nil? ? dump_object(value) : nil
          when :hash
            !value.nil? ? dump_object(value) : nil
          when :datetime
            !value.nil? ? value.to_time.to_f : nil
          when :serialized
            options[:serializer] ? options[:serializer].dump(value) : value.to_yaml
          when :boolean
            if(!value.nil?)
              if [true, false].include?(value)
                value
              else
                raise ArgumentError, "Boolean column neither true nor false"
              end
            else
              nil
            end
          else
            raise ArgumentError, "Unknown type #{options[:type]}"
        end
      end
    end

    # Convert empty strings to nil in objects since DynamoDB does not allow
    # empty strings in the database.
    def dump_object(obj)
      case obj
      when Hash
        obj.inject({}) do |new_hash, (key, value)|
          new_hash[key] = (value == '' ? nil : dump_object(value))
          new_hash
        end
      when Array, Set
        new_obj = obj.class.new
        obj.each do |value|
          new_obj << (value == '' ? nil : dump_object(value))
        end
        new_obj
      else
        obj
      end
    end

    # Persist the object into the datastore. Assign it an id first if it doesn't have one.
    #
    # @since 0.2.0
    def persist(conditions = nil)
      run_callbacks(:save) do
        self.hash_key = SecureRandom.uuid if self.hash_key.nil? || self.hash_key.blank?

        # Add an exists check to prevent overwriting existing records with new ones
        if(new_record?)
          conditions ||= {}
          (conditions[:unless_exists] ||= []) << self.class.hash_key
        end

        # Add an optimistic locking check if the lock_version column exists
        if(self.class.attributes[:lock_version])
          conditions ||= {}
          self.lock_version = (lock_version || 0) + 1
          #Uses the original lock_version value from ActiveModel::Dirty in case user changed lock_version manually
          (conditions[:if] ||= {})[:lock_version] = changes[:lock_version][0] if(changes[:lock_version][0])
        end

        begin
          Dynamoid.adapter.write(self.class.table_name, self.dump, conditions)
          @new_record = false
          true
        rescue Dynamoid::Errors::ConditionalCheckFailedException => e
          if new_record?
            raise Dynamoid::Errors::RecordNotUnique.new(e, self)
          else
            raise Dynamoid::Errors::StaleObjectError.new(self, 'persist')
          end
        end
      end
    end
  end
end
