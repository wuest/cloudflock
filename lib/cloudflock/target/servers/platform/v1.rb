require 'cloudflock/target/servers/platform'

# Public: Serves as a small class to easily map host specifications to Image
# and Flavor IDs in Rackspace Cloud.
#
# Examples
#
#   # Build platform data for a given CPE object
#   platform = Platform.new(cpe)
#   platform.image_id
#   # => Fixnum
class CloudFlock::Target::Servers::Platform::V1 <
      CloudFlock::Target::Servers::Platform
  # Public: Build the class constant Hashes for mapping given Platforms to
  # Rackspace Cloud Image IDs.
  #
  # Returns nothing.
  def build_image_maps
    self.class.const_set(:UNMANAGED_MAP, {
      amazon:
      {
        "*" => 118
      },
      arch:
      {
        "*" => 118
      },
      centos:
      {
        "5" => 114, "6" => 118
      },
      debian:
      {
        "5" => 103, "6" => 104
      },
      fedora:
      {
        "14" => 106, "15" => 116,
        "16" => 120, "17" => 126
      },
      gentoo:
      {
        "*" => 108
      },
      redhat:
      {
        "5" => 110, "6" => 111
      },
      ubuntu:
      {
        "*" => 10,
        "10.04" => 49, "10.10" => 49,
        "11.04" => 115, "11.10" => 119,
        "12.04" => 125, "12.10" => 125
      }
    })

    self.class.const_set(:MANAGED_MAP, {
      amazon:
      {
        "*" => 212
      },
      centos:
      {
        "5" => 200, "6" => 212
      },
      redhat:
      {
        "5" => 202, "6" => 204
      },
      ubuntu:
      {
        "*" => 206,
        "10.04" => 206, "10.10" => 206,
        "11.04" => 210, "11.10" => 214,
        "12.04" => 216
      }
    })
  end

  # Public: Build the class constant Hash for mapping server sizes to available
  # Rackspace Cloud Flavor IDs.
  #
  # Returns nothing.
  def build_flavor_maps
    self.class.const_set(:FLAVOR_LIST, [
      {id: 1, mem: 256, hdd: 10},
      {id: 2, mem: 512, hdd: 20},
      {id: 3, mem: 1024, hdd: 40},
      {id: 4, mem: 2048, hdd: 80},
      {id: 5, mem: 4096, hdd: 160},
      {id: 6, mem: 8192, hdd: 320},
      {id: 7, mem: 15872, hdd: 620},
      {id: 8, mem: 30720, hdd: 1200}
    ])
  end
end
