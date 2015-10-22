FactoryGirl.define do
  factory :md_state do
    name 'Maryland'
    abbr 'MD'

    country do |country|
      country.association(:country)
    end
  end
end
