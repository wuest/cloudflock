require 'cloudflock/target/servers/platform'

# Public: Override the Platform class provided by the servers provider to build
# Image ID maps corresponding to to Rackspace Open Cloud UUIDs.
class CloudFlock::Target::Servers::Platform::V2 <
      CloudFlock::Target::Servers::Platform
  # Public: Build the class constant Hashes for mapping given Platforms to
  # Rackspace Open Cloud Image IDs.
  #
  # Returns nothing.
  def build_image_maps
    self.class.const_set(:UNMANAGED_MAP, {
      amazon:
      {
        "*" => "a3a2c42f-575f-4381-9c6d-fcd3b7d07d17"
      },
      arch:
      {
        "*" => "c94f5e59-0760-467a-ae70-9a37cfa6b94e"
      },
      centos:
      {
        "5" => "03318d19-b6e6-4092-9b5c-4758ee0ada60",
        "6" => "a3a2c42f-575f-4381-9c6d-fcd3b7d07d17"
      },
      debian:
      {
        "6" => "a10eacf7-ac15-4225-b533-5744f1fe47c1"
      },
      fedora:
      {
        "16" => "bca91446-e60e-42e7-9e39-0582e7e20fb9",
        "17" => "d42f821e-c2d1-4796-9f07-af5ed7912d0e"
      },
      gentoo:
      {
        "*" => "110d5bd8-a0dc-4cf5-8e75-149a58c17bbf"
      },
      redhat:
      {
        "5" => "644be485-411d-4bac-aba5-5f60641d92b5",
        "6" => "d6dd6c70-a122-4391-91a8-decb1a356549"
      },
      ubuntu:
      {
        "10.04" => "d531a2dd-7ae9-4407-bb5a-e5ea03303d98",
        "11.04" => "8bf22129-8483-462b-a020-1754ec822770",
        "11.10" => "3afe97b2-26dc-49c5-a2cc-a2fc8d80c001",
        "12.04" => "5cebb13a-f783-4f8c-8058-c4182c724ccd",
        "12.10" => "ead43b0d-f84f-4bc1-8682-5b6046e69552",
        "13.04" => "9e1a83cf-ba21-44b6-8808-5837e291cfe2",
        "13.10" => "868a0966-0553-42fe-b8b3-5cadc0e0b3c5"
      }
    })

    self.class.const_set(:MANAGED_MAP, {
    	amazon:
    	{
    		"*" => "c195ef3b-9195-4474-b6f7-16e5bd86acd0"
    	},
    	centos:
    	{
    		"5" => "03318d19-b6e6-4092-9b5c-4758ee0ada60",
    		"6" => "c195ef3b-9195-4474-b6f7-16e5bd86acd0"
    	},
    	redhat:
    	{
    		"5" => "644be485-411d-4bac-aba5-5f60641d92b5",
    		"6" => "d6dd6c70-a122-4391-91a8-decb1a356549"
    	},
    	ubuntu:
    	{
    		"10.04" => "d531a2dd-7ae9-4407-bb5a-e5ea03303d98",
    		"11.04" => "8bf22129-8483-462b-a020-1754ec822770",
    		"11.10" => "3afe97b2-26dc-49c5-a2cc-a2fc8d80c001",
    		"12.04" => "5cebb13a-f783-4f8c-8058-c4182c724ccd",
        "12.10" => "ead43b0d-f84f-4bc1-8682-5b6046e69552",
        "13.04" => "9e1a83cf-ba21-44b6-8808-5837e291cfe2",
        "13.10" => "868a0966-0553-42fe-b8b3-5cadc0e0b3c5"
    	}
    })
  end

  # Public: Build the class constant Hash for mapping server sizes to available
  # Rackspace Cloud Flavor IDs.
  #
  # Returns nothing.
  def build_flavor_maps
    self.class.const_set(:FLAVOR_LIST, [
      {id: 2, mem: 512, hdd: 20},
      {id: 3, mem: 1024, hdd: 40},
      {id: 4, mem: 2048, hdd: 80},
      {id: 5, mem: 4096, hdd: 160},
      {id: 6, mem: 8192, hdd: 320},
      {id: 7, mem: 15872, hdd: 620},
      {id: 8, mem: 30720, hdd: 1200},
      {id: "performance1-1", mem: 1024, hdd: 20},
      {id: "performance1-2", mem: 2048, hdd: 60},
      {id: "performance1-4", mem: 4096, hdd: 80},
      {id: "performance1-8", mem: 8192, hdd: 120},
      {id: "performance2-15", mem: 15360, hdd: 190},
      {id: "performance2-30", mem: 30720, hdd: 340},
      {id: "performance2-60", mem: 61440, hdd: 640},
      {id: "performance2-90", mem: 92160, hdd: 940},
      {id: "performance2-120", mem: 122880, hdd: 1240}
    ].reduce({}) {|list, flavor| list[flavor[:id]] = flavor; list })
  end
end
