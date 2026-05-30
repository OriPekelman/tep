##
# Easily convert between latitude and longitude coordinates the the Maidenhead
# Locator System coordinates.
class Maidenhead
  #
  # Verify that the provided Maidenhead locator string is valid.
  #
  def self.valid_maidenhead?(location)
    return false unless location.is_a?String
    return false unless location.length >= 2
    return false unless (location.length % 2) == 0

    length = location.length / 2
    length.times do |counter|
      grid = location[counter * 2, 2]
      if (counter == 0)
        return false unless grid =~ /[a-rA-R]{2}/
      elsif (counter % 2) == 0
        return false unless grid =~ /[a-xA-X]{2}/
      else
        return false unless grid =~ /[0-9]{2}/
      end
    end

    true
  end

  #
  # Convert from a Maidenhead locator string to latitude and longitude.
  # Location may be between 1 and 5 grids in size (2 to 10 characters).
  # Longer values may work, but accuracy is not guaranteed as latitude
  # and longitude values returned are rounded ot 6 decimal places.
  #
  # For each grid, an arbitrary but repeatable latitude and longitude
  # is returned.
  #
  def self.to_latlon(location)
    maidenhead = Maidenhead.new
    maidenhead.locator = location
    [ maidenhead.lat, maidenhead.lon ]
  end

  #
  # Set the locator string.  It must be a valid string, or an ArgumentError
  # will be raised.  This also directly computes the latitude and longitude
  # values for this locator, so they will be valid after caling this method.
  #
  def locator=(location)
    unless Maidenhead.valid_maidenhead?(location)
      raise ArgumentError.new("Location is not a valid Maidenhead Locator System string")
    end

    @locator = location
    @lat = -90.0
    @lon = -180.0

    pad_locator

    convert_part_to_latlon(0, 1)
    convert_part_to_latlon(1, 10)
    convert_part_to_latlon(2, 10 * 24)
    convert_part_to_latlon(3, 10 * 24 * 10)
    convert_part_to_latlon(4, 10 * 24 * 10 * 24)
  end

  #
  # Convert from latitude and longitude to a Maidenhead locator string.
  # Latitude should be between -90 and 90, and longitude should be between
  # -180 and 180.  Precision defaults to 5 blocks, which returns 10 characters.
  # More precise coordinates may work, but accuracy is not guaranteed.
  #
  def self.to_maidenhead(lat, lon, precision = 5)
    maidenhead = Maidenhead.new
    maidenhead.lat = lat
    maidenhead.lon = lon
    maidenhead.precision = precision
    maidenhead.locator
  end

  #
  # Set the latitude.  Values must be between -90.0 and +90.0 or an
  # ArgumentError will be raised.
  #
  def lat=(pos)
    @lat = range_check("lat", 90.0, pos)
  end

  #
  # Retrieve the latitude, usually post-conversion from a locator string.
  # The result is rounded to 6 decimal places.
  #
  def lat
    @lat.round(6)
  end

  #
  # Set the longitude.  Values must be between -180.0 and +180.0 or an
  # ArgumentError will be raised.
  #
  def lon=(pos)
    @lon = range_check("lon", 180.0, pos)
  end

  #
  # Retrieve the longitude, usually post-conversion from a locator string.
  # The result is rounded to 6 decimal places.
  #
  def lon
    @lon.round(6)
  end

  #
  # Set the desired precision when converting from a latitude / longitude
  # to a maidenhead locator.  This specifies the number of groups to use,
  # usually 2 through 5, which results in 4 through 10 characters.
  #
  def precision=(value)
    @precision = value
  end

  def precision
    @precision
  end

  #
  # Convert from a latitude / longitude position, which must have been
  # set via #lat= and #lon=, to a locator.
  #
  def locator
    @locator = ''

    @lat_tmp = @lat + 90.0
    @lon_tmp = @lon + 180.0
    @precision_tmp = @precision

    calculate_field
    calculate_values

    @locator
  end

  private

  def pad_locator
    length = @locator.length / 2
    while (length < 5)
      if (length % 2) == 1
        @locator += '55'
      else
        @locator += 'LL'
      end
      length = @locator.length / 2
    end
  end

  def convert_part_to_latlon(counter, divisor)
    grid_lon = @locator[counter * 2, 1]
    grid_lat = @locator[counter * 2 + 1, 1]

    @lat += l2n(grid_lat) * 10.0 / divisor
    @lon += l2n(grid_lon) * 20.0 / divisor
  end

  def calculate_field
    @lat_tmp = (@lat_tmp / 10) + 0.0000001
    @lon_tmp = (@lon_tmp / 20) + 0.0000001
    @locator += n2l(@lon_tmp.floor).upcase + n2l(@lat_tmp.floor).upcase
    @precision_tmp -= 1
  end

  def compute_locator(counter, divisor)
    @lat_tmp = (@lat_tmp - @lat_tmp.floor) * divisor
    @lon_tmp = (@lon_tmp - @lon_tmp.floor) * divisor

    if (counter % 2) == 0
      @locator += "#{@lon_tmp.floor}#{@lat_tmp.floor}"
    else
      @locator += n2l(@lon_tmp.floor) + n2l(@lat_tmp.floor)
    end
  end

  def calculate_values
    @precision_tmp.times do |counter|
      if (counter % 2) == 0
        compute_locator(counter, 10)
      else
        compute_locator(counter, 24)
      end
    end
  end

  def l2n(letter)
    if letter =~ /[0-9]+/
      letter.to_i
    else
      letter.downcase.ord - 97
    end
  end

  def n2l(number)
    (number + 97).chr
  end

  def range_check(target, range, pos)
    pos = pos.to_f
    if pos < -range or pos > range
      raise ArgumentError.new("#{target} must be between -#{range} and +#{range}")
    end
    pos
  end
end
