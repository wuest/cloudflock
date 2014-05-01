require 'thread'
require 'tempfile'
require 'cloudflock/remote/files'
require 'cloudflock/app/common/rackspace'
require 'cloudflock/app'

module CloudFlock; module App
  # Public: The FilesMigrate class provides the interface to perform migrations
  # to and from Cloud Files containers, S3 buckets, and local file stores.
  class FilesMigrate
    include CloudFlock::App::Rackspace
    include CloudFlock::Remote

    # Default number of threads to be used to upload staged files.
    UPLOAD_THREADS   = 20

    # Default number of threads to be used to download files to staging area.
    DOWNLOAD_THREADS = 20

    # Public: Perform the steps necessary to migrate files from one file store
    # to another.
    def initialize
      options      = parse_options
      source_store = define_source
      dest_store   = define_destination

      UI.spinner('Migrating files') do
        files_migrate(source_store, dest_store, options)
      end
    end

    private

    # Internal: Gather information for and connect to the source store.
    #
    # Returns a CloudFlock::Remote::Files object.
    def define_source
      define_api('Source')
    end

    # Internal: Gather information for and connect to the destination store.
    #
    # Returns a CloudFlock::Remote::Files object.
    def define_destination
      define_api('Destination', true)
    end

    # Internal: Obtain information needed to connect to a data store.
    #
    # desc   - Description of the data store for display purposes.
    # create - Whether to create non-existing locations. (default: false)
    #
    # Returns a CloudFlock::Remote::Files object.
    def define_api(desc, create = false)
      query   = "#{desc} provider (rackspace, aws, local)"
      answers = [/^(?:rackspace|aws|local)$/i]

      provider = UI.prompt(query, valid_answers: answers)

      api = case provider
      when /rackspace/i
        define_rackspace_api
      when /aws/i
        {
          provider: 'AWS',
          aws_access_key_id: UI.prompt('AWS Access Key ID'),
          aws_secret_access_key: UI.prompt('AWS secret access key')
        }
      when /local/i
        {
          provider:   'local',
          local_root: UI.prompt("#{desc} location")
        }
      end

      store = api.merge(define_rackspace_files_region(api))
      setup_object_store(CloudFlock::Remote::Files.new(store), desc, create)
    end

    # Internal: Connect to an object store and determine the directory on which
    # to act.
    #
    # store  - Fog::Remote::Files object.
    # desc   - Description of the data store for display purposes.
    # create - Whether to create non-existing locations.
    #
    # Returns a CloudFlock::Remote::Files object.
    def setup_object_store(store, desc, create)
      return store if store.local?

      options = store.directories.map do |dir|
        { name: dir.key, files: dir.count.to_s }
      end
      valid = options.reduce([]) { |c,e| c << e[:name] }

      puts UI.build_grid(options, name: "Directory name", files: "File count")
      if create
        selected = UI.prompt("#{desc} directory")
        unless store.directories.select { |dir| dir.key == selected }.any?
          store.directories.create(key: selected)
        end
      else
        selected = UI.prompt("#{desc} directory", valid_answers: valid)
      end
      store.directory = selected

      store
    end

    # Internal: Set up queue and Mutexes, create threads to manage the transfer
    # of files from source to destination.
    #
    # source_store - CloudFlock::Remote::Files object set up to pull files from
    #                a source directory.
    # dest_store   - CloudFlock::Remote::Files object set up to create files as
    #                they are uploaded.
    # options      - Hash optionally containing overrides for the number of
    #                upload and download threads to use for transfer
    #                concurrency. (default: {})
    #                :upload_threads   - Number of upload threads to use.
    #                                    Overrides UPLOAD_THREADS constant.
    #                :download_threads - Number of download threads to use.
    #                                    Overrides DOWNLOAD_THREADS constant.
    #
    # Returns nothing.
    def files_migrate(source_store, dest_store, options = {})
      mutexes      = { queue: Queue.new, ongoing: Mutex.new }
      up_threads   = options[:upload_threads]   || UPLOAD_THREADS
      down_threads = options[:download_threads] || DOWNLOAD_THREADS

      mutexes[:ongoing].lock
      destination = Thread.new do
        manage_destination(dest_store, mutexes, down_threads)
      end

      source = Thread.new do
        manage_source(source_store, mutexes, up_threads)
        mutexes[:ongoing].unlock
      end

      [source, destination].each(&:join)
    end

    # Internal: Create and observe threads which download files from a
    # non-local file store.  If the files exist locally, simply generate a list
    # of the files in queue.
    #
    # store        - CloudFlock::Remote::Files object set up to pull files from
    #                a source directory.
    # mutexes      - Hash containing two Mutexes:
    #                :queue   - Queue to coordinate file access.
    #                :ongoing - Indicates that the transfer is ongoing when
    #                           locked.
    # thread_count - Hash optionally containing overrides for the number of
    #                upload and download threads to use for transfer
    #                concurrency. (default: {})
    #                :upload_threads   - Number of upload threads to use.
    #                                    Overrides UPLOAD_THREADS constant.
    #                :download_threads - Number of download threads to use.
    #                                    Overrides DOWNLOAD_THREADS constant.
    #
    # Returns nothing.
    def manage_source(store, mutexes, thread_count)
      if store.local?
        store.each_file do |file|
          node = File.new("#{store.prefix}/#{file.key}")
          mutexes[:queue] << { file: node, name: file.key, temp: false }
        end
      else
        source_threads  = []
        file_list_mutex = Mutex.new
        file_list       = store.file_list

        thread_count.times do
          source_threads << Thread.new do
            while file = file_list_mutex.synchronize { file_list.pop } do
              temp = Tempfile.new(file.gsub(/\//, ''))
              temp.write(store.get_file(file))
              temp.close
              mutexes[:queue] << { file: temp, name: file, temp: true }
            end
          end
        end

        source_threads.each(&:join)
      end
    end

    # Internal: Create and observe threads which download files from a
    # non-local file store.  If the files exist locally, simply generate a list
    # of the files in queue.
    #
    # dest_store   - CloudFlock::Remote::Files object set up to upload files to
    #                a destination directory.
    # mutexes      - Hash containing two Mutexes:
    #                :queue   - Queue to coordinate file access.
    #                :ongoing - Indicates that the transfer is ongoing when
    #                           locked.
    # thread_count - Hash optionally containing overrides for the number of
    #                upload and download threads to use for transfer
    #                concurrency. (default: {})
    #                :upload_threads   - Number of upload threads to use.
    #                                    Overrides UPLOAD_THREADS constant.
    #                :download_threads - Number of download threads to use.
    #                                    Overrides DOWNLOAD_THREADS constant.
    #
    # Returns nothing.
    def manage_destination(dest_store, mutexes, thread_count)
      dest_threads = []

      thread_count.times do
        dest_threads << Thread.new do
          upload_thread(dest_store, mutexes)
        end
      end

      dest_threads.each(&:join)
    end

    # Internal: Upload files from a Queue to a given object store.
    #
    # dest_store   - CloudFlock::Remote::Files object set up to upload files to
    #                a destination directory.
    # mutexes      - Hash containing two Mutexes:
    #                :queue   - Queue to coordinate file access.
    #                :ongoing - Indicates that the transfer is ongoing when
    #                           locked.
    #
    # Returns nothing.
    def upload_thread(dest_store, mutexes)
      while mutexes[:ongoing].locked?
        while file = mutexes[:queue].pop(true)
          file[:file].open if file[:temp]
          dest_store.create(key: file[:name], body: file[:file].read)
          file[:file].close
        end
      end
    rescue ThreadError
      sleep 0.1
      retry
    end

    # Internal: Set up an OptionParser object to recognize options specific to
    # profiling a remote host.
    #
    # Returns nothing.
    def parse_options
      options = {}

      CloudFlock::App.parse_options(options) do |opts|
        opts.separator 'Migrate files between file stores'
        opts.separator ''

        opts.on('-u', '--upload-threads THREADS',
                'Number of upload threads to use (default 20)') do |threads|
          options[:upload_threads] = threads.to_i if threads.to_i > 0
        end
        opts.on('-d', '--download-threads THREADS',
                'Number of download threads to use (default 20)') do |threads|
          options[:download_threads] = threads.to_i if threads.to_i > 0
        end
      end
    end
  end
end; end
