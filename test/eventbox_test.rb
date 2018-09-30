require_relative "test_helper"

class EventboxTest < Minitest::Test

  def test_that_it_has_a_version_number
    assert_match(/\A\d+\.\d+\.\d+/, ::Eventbox::VERSION)
  end

end
