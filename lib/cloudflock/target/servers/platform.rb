require 'cpe'
require 'cloudflock'

# Public: Serves as a small class to easily map host specifications to Image
# and Flavor IDs in Rackspace Cloud.
#
# Examples
#
#   # Build platform data for a given CPE object
#   platform = Platform.new(cpe)
#   platform.image_id
#   # => Fixnum
class CloudFlock::Target::Servers::Platform
  # Public: Gets/sets whether the target platform will be managed.
  attr_accessor :managed
  # Public: Gets/sets whether the target platform will use Rack Connect.
  attr_accessor :rack_connect

  # Public: Initialize the Platform object.
  #
  # cpe - CPE object from which to generate platform object.
  #
  # Raises ArgumentError if anything but a CPE object was given.
  # Raises KeyError if the CPE object doesn't have a vendor or version defined.
  def initialize(cpe)
    raise ArgumentError unless cpe.kind_of?(CPE)
    raise KeyError if cpe.vendor.nil? or cpe.version.nil?

    @cpe = cpe
    @distro = cpe.vendor
    @product = cpe.product
    @version = cpe.version
    @managed = false
    @rack_connect = false

    build_maps
  end

  # Public: Generate a String of the platform's name/version suitable for
  # display
  #
  # Returns a String describing the Platform
  def to_s
    "#{@distro.capitalize} #{@product.gsub(/_/, ' ').capitalize} #{@version}"
  end

  # Public: Return the Image ID to be used based on whether the account is
  # managed, and the platform used
  #
  # Returns the Image ID corresponding to the Platform object as a String
  def image
    [:MANAGED_MAP, :UNMANAGED_MAP].each do |map|
      unless self.class.const_defined?(map)
        raise MapUndefined, "Const #{map} is undefined; maps appear unbuilt"
      end
    end

    map = @managed ? self.class::MANAGED_MAP : self.class::UNMANAGED_MAP
    distro = @distro.downcase.to_sym

    unless map[distro].nil?
      return map[distro][@version] unless map[distro][@version].nil?
      return map[distro]["*"] unless map[distro]["*"].nil?
    end

    nil
  end

  # Public: Iterate through TARGET_LIST until a suitably large flavor_id is
  # found, then return the appropriate index.  If no entry can be found, raise
  # ValueError.
  #
  # symbol - A Symbol referencing the search target in TARGET_LIST.
  # value  - A Fixnum containing the amount of memory or disk space required.
  #
  # Returns a Fixnum referencing the TARGET_LIST index.
  # Raises ValueError if no symbol describes an appropriate target.
  def get_target_by_symbol(symbol, value)
    unless self.class.const_defined?(:FLAVOR_LIST)
      raise MapUndefined, "FLAVOR_LIST is undefined; maps appear unbuild."
    end

    self.class::FLAVOR_LIST.each do |idx, target|
      if target[symbol] > value
        return idx
      end
    end

    raise ValueError, "Unable to find a flavor matching #{symbol} #{value}"
  end

  # Internal: Build image and flavor maps
  #
  # Returns nothing
  def build_maps
    build_image_maps
    build_flavor_maps
  end

  # Public: Give a recommendation for a Flavor ID and an Image ID which should
  # suffice for a migration target host.
  #
  # args - Hash containing information on which to base the recommendation:
  #        :memory  - Hash containing memory information:
  #                   :total     - Total amount of memory allocated to the host
  #                                profiled.
  #                   :mem_used  - Amount of RAM in use at the time of
  #                                profiling.
  #                   :swapping? - Boolean denoting whether the host was
  #                                swapping at the time of profiling.
  #        :disk    - Fixnum containing the amount of disk which appears to be
  #                   in use at the time of profiling.
  #
  # Returns a Hash containing the Flavor ID and a String containing the
  # reasoning for the decision.
  def build_recommendation(args)
    recommendation = {}
    target_mem = get_target_by_symbol(:mem, args[:memory][:mem_used])
    target_mem += 1 if args[:memory][:swapping?]

    target_disk = get_target_by_symbol(:hdd, args[:disk])

    if target_mem >= target_disk
      recommendation[:flavor] = target_mem
      recommendation[:flavor_reason] = "RAM usage"
    else
      recommendation[:flavor] = target_disk
      recommendation[:flavor_reason] = "Disk usage"
    end

    recommendation
  end
end
