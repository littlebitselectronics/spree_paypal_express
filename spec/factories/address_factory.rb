FactoryGirl.define do
  factory :ppx_address, class: Spree::Address do
    firstname 'John'
    lastname 'Doe'
    address1 '10 Lovely Street'
    address2 'Northwest'
    city   "Herndon"
    state  { |state| state.association(:ppx_state) }
    zipcode '20170'
    country { |country| country.association(:country) }
    phone '123-456-7890'
    state_name "maryland"
    alternative_phone "123-456-7899"
  end
end
