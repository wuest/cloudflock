require 'cloudflock'

# Public: Provide an interface to instantiate Fog::Storage instances, perform
# basic sanity checking for the local provider.
module CloudFlock::Remote::Files extend self
  # Public: Set up and verify a data source.
  #
  # target - Hash containing connection details per Fog requirements, a String
  #          containing the path to a local directory.
  #
  # Returns an instance of a Files subclass.
  def connect(target)
    target = { provider: 'local', local_root: target } if target.is_a?(String)
    raise ArgumentError, "String or Hash expected" unless target.is_a?(Hash)

    if target[:provider].downcase == 'local'
      target_parent = File.expand_path(target[:local_root], '..')
      unless File.exists?(target_parent)
        raise Errno::ENOENT, "#{target_parent} does not exist"
      end
      unless File.directory?(target_parent)
        raise Errno::ENOENT, "#{target_parent} is not a directory"
      end
    end

    Fog::Storage.new(target)
  end
end
