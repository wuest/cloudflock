require 'fog'
require 'cloudflock/target/servers'
require 'cloudflock/interface/cli/app/common/servers'

# Public: The Servers::Migrate app provides the interface to Servers migrations
# (primarily targeting Managed/Unmanaged Rackspace First-gen and Open Cloud,
# but other migrations are possible) on the CLI.
class CloudFlock::Interface::CLI::App::Servers::Migrate
  include CloudFlock::Interface::CLI::App::Common::Servers
  CLI = CloudFlock::Interface::CLI::Console

  # Public: Begin Servers migration on the command line
  #
  # opts - Hash containing options mappings.
  def initialize(opts)
    opencloud = (opts[:function] == :opencloud)

    resume = opts[:resume]
    source_host_def = define_source(opts[:config])
    source_host_ssh = CLI.spinner("Logging in to #{source_host_def[:host]}") do
      host_login(source_host_def)
    end

    source_profile = CLI.spinner("Checking source host") do
      profile = Profile.new(source_host_ssh)
      profile.build
      profile
    end

    if opencloud
      target_platform = Platform::V2
    else
      target_platform = Platform::V1
    end
    platform = target_platform.new(source_profile[:cpe])
    build_target = platform.build_recommendation(source_profile)
    flavor_list = target_platform::FLAVOR_LIST
    default_target = flavor_list[build_target[:flavor]]

    # Generate and display a brief summary of the server Platform/Profile
    os_tag = source_profile[:cpe].vendor == "Unknown" ? CLI.red : CLI.blue
    ram_qty = default_target[:mem]
    hdd_qty = default_target[:hdd]
    decision_reason = "#{CLI.bold}#{build_target[:flavor_reason]}#{CLI.reset}"

    puts "OS: #{CLI.bold}#{os_tag}#{platform}#{CLI.reset}"
    puts "---"
    puts "Recommended server:"
    puts "RAM: #{CLI.bold} % 6d MiB#{CLI.reset}" % ram_qty
    puts "HDD: #{CLI.bold} % 7d GB#{CLI.reset}" % hdd_qty
    puts "The reason for this decision is: #{decision_reason}"
    puts "---"
    unless source_profile.warnings.empty?
      print CLI.red + CLI.bold
      source_profile.warnings.each { |warning| puts warning }
      print CLI.reset
      puts "---"
    end

    if resume
      destination_host_def = define_destination
      migration_exclusions = determine_exclusions(source_profile[:cpe])
      platform.managed = CLI.prompt_yn("Managed service level? (Y/N)",
                                       default_answer: "Y")
      platform.rack_connect = CLI.prompt_yn("Rack Connected? (Y/N)",
                                            default_answer: "N")
    else
      api = {}
      api[:version] = opencloud ? :v2 : :v1

      proceed = CLI.prompt_yn("Spin up this server? (Y/N)", default_answer: "Y")
      if proceed
        api[:flavor] = default_target[:id]
      else
        puts CLI.build_grid(flavor_list, 
                            {id: "ID", mem: "RAM (MiB)", hdd: "HDD (GB)" })
        api[:flavor] = CLI.prompt("Flavor ID",
                                  default_answer: default_target[:id])
        api[:flavor] = api[:flavor].to_i
      end

      migration_exclusions = determine_exclusions(source_profile[:cpe])
      platform.managed = CLI.prompt_yn("Managed service level? (Y/N)",
                                       default_answer: "Y")
      platform.rack_connect = CLI.prompt_yn("Rack Connected? (Y/N)",
                                            default_answer: "N")

      # Warn against Rack Connect
      if platform.rack_connect
        puts "#{CLI.bold}#{CLI.red}*** Rack Connect servers might not " +
             "provision properly when spun up from the API!  Resume " +
             "recommended!#{CLI.reset}"
        sleep 5
      end


      # Check to make sure we have a valid flavor ID
      exit 0 if api[:flavor] == 0 or flavor_list[api[:flavor]-1].nil?

      # Build our API call
      api[:hostname] = CLI.prompt("New Server Name",
                                   default_answer: source_profile[:hostname])

      # OpenCloud only supports US migrations presently
      if opts[:function] == :opencloud
        api[:region] = CLI.prompt("Region (dfw, ord)", default_answer: "dfw",
                            valid_answers: ["ord", "dfw"])
      else
        api[:region] = :dfw
      end

      api[:username] = CLI.prompt("RS Cloud Username")
      api[:api_key] = CLI.prompt("RS Cloud API key")

      # Name cannot have any special characters in it
      api[:hostname].gsub!(/[^A-Za-z0-9.]/, '-')

      rack_api = Fog::Compute.new(provider: 'rackspace',
                                     rackspace_username: api[:username],
                                     rackspace_api_key: api[:api_key],
                                     rackspace_region: api[:region],
                                     version: api[:version])

      # Rescue patch has to be loaded after the connection is created
      require 'cloudflock/patch/fog'

      # Send API call
      new_server = CLI.spinner("Spinning up new server: #{api[:hostname]}") do
        rack_api.servers::create(name: api[:hostname],
                                 image_id: platform.image,
                                 flavor_id: api[:flavor])

      end

      # Set the destination host address
      destination_host_def = {}
      CLI.spinner("Obtaining information for new instance") do
        # Obtain the administrative pass for the new host.
        destination_host_def[:password] = new_server.password
        server_id = new_server.id

        until new_server.state == 'ACTIVE'
          sleep 30
          begin
            new_server.update
          rescue NoMethodError
            new_server.reload
          end
        end

        if opencloud
          dest_host = new_server.addresses["public"].select do |e|
            e["version"] == 4
          end
          destination_host_def[:host] = dest_host[0]["addr"]
        else
          destination_host_def[:host] = new_server.addresses["public"][0]
        end
      end

      # If we're working within the Managed service level, ensure that Chef
      # has finished successfully
      if platform.managed
        r = 0
        destination_host_ssh = destination_login(destination_host_def)

        begin
          message =
          finished = CLI.spinner("Waiting for Chef to finish") do
            # Sleep 180 seconds before trying
            sleep 180
            Migrate.setup_managed(destination_host_ssh)
          end
          unless finished
            panic = "#{CLI.bold}#{CLI.red}*** MGC Cloud Scripts appear to " +
                    "have failed to run in a reasonable amount of time." +
                    "#{CLI.reset}"
            puts panic
            exit unless CLI.prompt_yn("Continue? (Y/N)", default_answer: "Y")
          end
          destination_host_ssh.logout!
        rescue
          panic = "#{CLI.bold}#{CLI.red}*** Unable to communicate with the " +
                  "destination host.  Bailing out.#{CLI.reset}"
          puts panic
          raise
        end
      end

      if opts[:function] == :opencloud
        host = destination_host_def[:host]
        CLI.spinner("Putting #{host} into rescue mode") do
          new_server.rescue
          destination_host_def[:password] = new_server.password
          new_server.update
        end
      else
        pass_prompt = "Please put #{api[:hostname]} into rescue mode and " +
                      "give password"
        destination_host_def[:password] = CLI.prompt(pass_prompt)
      end

      CLI.spinner "Letting rescue mode come up..." do
        until new_server.state == 'RESCUE'
          sleep 30
          begin
            new_server.update
          rescue NoMethodError
            sleep 60
            new_server.reload
          end
        end
      end

      Thread.new do
        continue = false
        until continue
          r = 0
          message = "Checking for SSH on #{destination_host_def[:host]}"
          ssh_command = "ssh #{SSH::SSH_ARGUMENTS} " +
                        "root@#{destination_host_def[:host]}"
          continue = CLI.spinner(message) do
            begin
              sleep 20
              ssh_expect = Expectr.new(ssh_command, flush_buffer: false)
              ssh_expect.expect("password")
            rescue
              retry if (r+=1) < 10
              raise
            end
          end
        end
      end.join
    end

    destination_host_ssh = destination_login(destination_host_def)

    unless destination_host_def[:pre_steps] == false
      # Attempt to set up the source host 5 times.  If there is a failure,
      # sleep for 60 seconds before retrying.
      r = 0
      begin
        message = "Setting up source host (attempt #{r + 1}/5)"
        pubkey = CLI.spinner(message) do
          begin
            message.gsub!(/\d\/5/, "#{r + 1}/5")
            sleep 60 unless r == 0
            Migrate.setup_source(source_host_ssh, migration_exclusions)
          rescue
            retry if (r += 1) < 5
            raise
          end
        end
      rescue
        panic = "#{CLI.bold}#{CLI.red}*** Unable to communicate with the " +
                "source host.  Bailing out.#{CLI.reset}"
        puts panic
        raise
      end

      # Attempt to set up the destination host 5 times.  If there is a
      # failure, sleep for 60 seconds before retrying.
      r = 0
      begin
        message = "Setting up destination host (attempt #{r + 1}/5)"
        CLI.spinner(message) do
          begin
            message.gsub!(/\d\/5/, "#{r + 1}/5")
            sleep 60 unless r == 0
            Migrate.setup_destination(destination_host_ssh, pubkey)
          rescue
            retry if (r += 1) < 5
            raise
          end
        end
      rescue
        panic = "#{CLI.bold}#{CLI.red}*** Unable to communicate with the " +
                "destination host.  Bailing out.#{CLI.reset}"
        puts panic
        raise
      end
    end

    # Determine if Service Net can be used
    begin
      CLI.spinner "Checking for ServiceNet" do
        target_addr = Migrate.check_servicenet(source_host_ssh,
                                               destination_host_ssh)
        raise if target_addr.nil?
        destination_host_def[:target_addr] = target_addr
      end
    rescue
      destination_host_def[:target_addr] = destination_host_def[:host]
    end

    # Set rsync path and no timeout for the migration rsync
    destination_host_def[:timeout] = -1
    destination_host_def[:rsync] = source_profile[:rsync]

    # Kick off the migration proper
    if opts[:verbose]
      Migrate.migrate_server(source_host_ssh, destination_host_def)
    else
      CLI.spinner "Performing migration" do
        Migrate.migrate_server(source_host_ssh, destination_host_def)
      end
    end

    CLI.spinner "Cleaning up destination host" do
      Migrate.clean_destination(destination_host_ssh, source_profile[:cpe])
    end

    [destination_host_ssh, source_host_ssh].each do |host|
      host.logout!
    end

    puts
    puts "#{CLI.bold}#{CLI.blue}*** Migration complete#{CLI.reset}\a"
  end

  # Internal: Ask whether or not to edit the default exclusion list for a given
  # platform, and facilitate the edit if so.
  #
  # cpe - CPE object for the host in question.
  #
  # Returns a String containing the exclusions.
  # Raises ArgumentError if cpe isn't a CPE object.
  def determine_exclusions(cpe)
    raise ArgumentError unless cpe.kind_of?(CPE)

    exclusion_string = Migrate.build_default_exclusions(cpe)
    alter = CLI.prompt_yn("Edit default exclusions list? (Y/N)",
                          default_answer: "N")

    if alter
      require 'tempfile'

      tmp_file = Tempfile.new("exclude")
      tmp_file.write(exclusion_string)
      tmp_file.close

      # Allow for "other" editors
      if File.exists?("/usr/bin/editor")
        editor = "/usr/bin/editor"
      else
        editor = "vim"
      end

      system("#{editor} #{tmp_file.path}")
      tmp_file.open
      exclusion_string = tmp_file.read
      tmp_file.close
      tmp_file.unlink
    end

    exclusion_string
  end
end
