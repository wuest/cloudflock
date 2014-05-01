require 'cloudflock'
require 'fog'

module CloudFlock; module Remote
  # Public: Provide a unified interface to instantiate various Fog::Storage
  # objects while providing sanity checking where applicable.
  class Files
    # Public: Gets the location prefix for local stores
    attr_reader :prefix

    # Public: Connect via API and store the Fog instance as well as relative
    # path information if a local store.
    #
    # store_spec - Hash containing data necessary to connect to an object
    #              storage service via Fog.
    def initialize(store_spec)
      @local = false
      if store_spec[:provider] == 'local'
        @local = true
        @prefix  = File.expand_path(store_spec[:local_root])
        location = File.basename(store_spec[:local_root])
        store_spec[:local_root] = File.expand_path(File.join(@prefix, '..'))
      end

      @fog = Fog::Storage.new(store_spec)
      self.directory = (location) if local?
    end

    # Public: Set the active directory for fetching/uploading files.
    #
    # location - String denoting a directory name to use.
    #
    # Returns nothing.
    def directory=(location)
      @files = @fog.directories.select { |dir| dir.key == location }.first
    end

    # Public: Wrap Fog::Storage#directories
    #
    # Returns Fog::Storage::*::Directories.
    def directories
      @fog.directories
    end

    # Public: Wrap Fog::Storage::Directory#each
    #
    # Yields Fog::Storage::File objects
    def each_file(&block)
      @files.files.each(&block)
    end

    # Public: Generate a list of all files in the current directory.
    #
    # Returns an array of Fog::Storage::File objects.
    def file_list
      @files.files.map(&:key)
    end

    # Public: Return the contents of a given file in the current directory.
    #
    # file - String containing the path to a file.
    #
    # Returns a String.
    def get_file(file)
      @files.files.get(file).body
    rescue Excon::Errors::Timeout, Fog::Storage::Rackspace::ServiceError
      # Triggered by server and request timeouts respectively.
      retry
    end

    # Public: Create a file in the current directory.
    #
    # file_spec - Hash containing info to create a new file:
    #             :key  - Path under which the file should be created.
    #             :body - Contents of the file to be created.
    # 
    # Returns nothing.
    def create(file_spec)
      @files.files.create(file_spec)
    rescue Excon::Errors::Timeout, Fog::Storage::Rackspace::ServiceError
      # Triggered by server and request timeouts respectively.
      retry
    end

    # Public: Report whether a local store is referenced.
    #
    # Returns whether the store is local to the host.
    def local?
      @local
    end
  end
end; end
