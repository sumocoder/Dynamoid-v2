class Address
  include Dynamoid::Document

  field :city
  field :options, :serialized
  field :deliverable, :boolean
  field :latitude, :number
  field :info, :hash

  field :lock_version, :integer #Provides Optimistic Locking

  def zip_code=(zip_code)
    self.city = "Chicago"
  end
end
