require 'cloudflock'
require 'cloudflock/interface/cli'
require 'cloudflock/remote/files'
require 'tempfile'
require 'thread'
require 'fog'

# Public: The Files app provides the interface to perform migrations of
# File/Object storage (e.g. Amazon S3, Local files and Rackspace Cloud Files).  
class CloudFlock::Interface::CLI::App::Files
  CLI = CloudFlock::Interface::CLI::Console

  DOWNLOAD_THREAD_COUNT = 4
  UPLOAD_THREAD_COUNT   = 4

  # Public: Begin Files migration on the command line
  #
  # opts - Hash containing options mappings.
  def initialize(opts)
    @options = opts
    @download_finished = false
    @download_mutex = Mutex.new
    @upload_mutex = Mutex.new
    @download_list = []
    @upload_list = []

    source_store = define_store("source")
    destination_store = define_store("destination")

    @source_container = define_container(source_store, "source")
    @destination_container = define_container(destination_store, "destination",
                                             true)

    if perform_migration
      puts "#{CLI.bold}#{CLI.blue}*** Migration complete#{CLI.reset}\a"
    else
      puts "#{CLI.bold}#{CLI.red}*** Migration failed#{CLI.reset}\a"
    end
  rescue Excon::Errors::Unauthorized => err
    puts "A provider has returned an Unauthorized error."
    puts err.inspect if @options[:verbose]
    exit 1
  end

  # Internal: Migrate objects from the source store to the destination store.
  #
  # Returns a boolean value corresponding to whether the migration has
  # completed successfully.
  def perform_migration
    download_threads = []
    upload_threads = []

    @source_container.files.each { |f| @download_list.push(f) }

    DOWNLOAD_THREAD_COUNT.times do
      download_threads << download_thread
    end
    UPLOAD_THREAD_COUNT.times do
      upload_threads << upload_thread
    end

    download_threads.each { |t| t.join }
    @download_finished = true
    upload_threads.each { |t| t.join }
    true
  rescue => e
    if @options[:verbose]
      puts "#{CLI.bold}#{CLI.red}*** Error ***#{CLI.reset}"
      puts e.inspect
      puts e.backtrace
      puts
    end
    false
  end

  # Internal: Create a new Thread to download objects from the source
  # container.
  #
  # Returns a Thread.
  def download_thread
    Thread.new do
      file = nil
      until @download_list.empty?
        @download_mutex.synchronize do
          file = @download_list.pop
        end
        next if file.nil?
        # AWS stores directories as their own object
        next if file.content_length == 0 && file.key =~ /\/$/

        tmp = Tempfile.new(file.object_id.to_s)
        @source_container.files.get(file.key) do |data, rem, cl|
          tmp.syswrite(data)
        end
        tmp.flush
        tmp.rewind
        @upload_mutex.synchronize do
          @upload_list.push(body: tmp, key: file.key)
        end
      end
    end
  end

  # Internal: Create a new Thread to upload objects to the desination
  # container.
  #
  # Returns a Thread.
  def upload_thread
    Thread.new do
      file = nil
      until @upload_list.empty? && @download_finished
        sleep 0.1
        @upload_mutex.synchronize do
          file = @upload_list.pop
        end
        next if file.nil?
        @destination_container.files.create(file)
      end
    end
  end

  # Internal: Ascertain the location for a data store.
  #
  # desc - String containing a description for the file store.
  #
  # Returns a Fog object pointing to the data store.
  # Raises ArgumentError if desc isn't a String.
  def define_store(desc)
    unless desc.kind_of?(String)
      raise ArgumentError, "String expected"
    end
    store = {}
    store[:provider] = CLI.prompt("#{desc} provider (aws, local, rax)",
                                  valid_answers: ["rax", "aws", "local"])
    case store[:provider]
    when 'rax'
      store[:provider] = 'Rackspace'
      store[:rackspace_username] = CLI.prompt("Rackspace username")
      store[:rackspace_api_key] = CLI.prompt("Rackspace API key")
    when 'aws'
      store[:provider] = 'AWS'
      store[:aws_access_key_id] = CLI.prompt("AWS Access Key ID")
      store[:aws_secret_access_key] = CLI.prompt("AWS secret access key")
    when 'local'
      store[:local_root] = CLI.prompt("#{desc} location")
    end

    CloudFlock::Remote::Files.connect(store)
  end

  # Internal: Obtain the name of a container.
  #
  # store  - Fog object pointing to a Fog::Storage object.
  # desc   - String containing a description for the container.
  # create - Boolean value indicating whether to create the container.
  #
  # Returns a Fog object pointing to the container.
  # Raises ArgumentError if store isn't a Fog::Storage object.
  # Raises ArgumentError if desc isn't a String.
  def define_container(store, desc, create=false)
    unless store.class.to_s =~ /^Fog::Storage/
      raise ArgumentError, "Fog Storage object expected"
    end
    unless desc.kind_of?(String)
      raise ArgumentError, "String expected"
    end

    if create
      container = CLI.prompt("#{desc} container name")
      return store.directories.create(key: container)
    else
      puts "Available containers:"
      puts store.directories.map(&:key)
      container = CLI.prompt("#{desc} container name",
                             valid_answers: store.directories.map(&:key))
      return store.directories.select { |i| i.key == container }[0]
    end
  end
end
