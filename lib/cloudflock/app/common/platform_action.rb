module CloudFlock; module App; module Common
  # Public: The PlatformAction Class provides the template for actions to be
  # taken dependant upon the platform targeted.
  class PlatformAction
    # Public: Gets the Array containing the platform details.
    attr_reader :platform

    # Public: Gets the path prefix for including any applicable files.
    attr_reader :prefix

    # Public: Set internal parameters and initialize an empty Hash to be used
    # as a collection.
    #
    # cpe - CPE object containing information off of which the platform
    #       parameters will be based.
    def initialize(cpe)
      classname = self.class.name.downcase.split(/::/).last
      @prefix     = "cloudflock/app/common/#{classname}/"
      @platform   = ['unix', cpe.vendor, cpe.product + cpe.version]
      @collection = {}
    end

    # Public: Map a block to the platform Array.
    #
    # Yields each item in platform (per map).
    def map_platforms(&block)
      platform.map(&block)
    end

    # Public: Applies a block to each item in the platform Array.
    #
    # Yields each item in platform (per each).
    def each_platform(&block)
      platform.each(&block)
    end

    # Public: Loads each available file corresponding to a given platform in
    # order of ascending specificity, then passes the Module to the block
    # passed.
    #
    # Yields each Module.
    def load_each(&block)
      platforms = map_platforms { |name| name.gsub(/[^a-zA-Z0-9]/, '_') }

      paths = (0...platforms.length).map { |i| platforms[(0...i)].join('/') }
      mods  = (0...platforms.length).map do |i|
        platforms[(0...i)].map(&:capitalize)
      end

      (0...paths.length).each do |index|
        begin
          require prefix + paths[index]
          block.call(mods[index].reduce(self.class) { |c,e| c.const_get(e) })
        rescue LoadError
        end
      end
    end
  end
end; end; end
