# Public: Provide methods to abstract and simplify interaction with a user via
# a command-line application.
#
# Examples
#
#   # prompt for a question with free-form input
#   answer = Console.prompt("Question")
#
#   # Print bolded text
#   puts "#{Console.bold}Bold text#{Console.reset}"
module CloudFlock::Interface::CLI::Console extend self
  # Public: Prompt user for input, allowing for a default answer and a list of
  # valid responses.
  #
  # question - String containing the question to present to the user.
  # args     - Hash containing arguments to control acceptable responses.
  #            (default: {}):
  #            :default_answer - String containing the default answer.  If the
  #            default is nil, a non-empty answer MUST be given.
  #            :valid_answers  - An Array containing all valid responses.
  #
  # Returns a String containing the answer provided by the user.
  def prompt(question, args = {})
    default = args[:default_answer].to_s
    allow_empty = !args[:default_answer].nil?
    valid = args[:valid_answers] || []

    default_display = default.empty? ? "" : "[%s]" % default.strip
    question.strip!

    acceptable = false
    until acceptable
      printf("%s %s> ", question, default_display)
      answer = $stdin.readline.strip

      if answer.empty? && allow_empty
        acceptable = true
      elsif valid.empty? && !answer.empty?
        acceptable = true
      elsif !(valid.grep(answer)).empty? && !valid.empty?
        acceptable = true
      end
    end

    answer.empty? ? default.to_s : answer
  end

  # Public: Wrap Console#prompt but require a Y/N response.
  #
  # question - String containing the question to present to the user.
  # args     - Hash containing arguments to control acceptable responses.
  #            (default: {}):
  #            :default_answer - String containing the default answer.
  #
  # Returns true or false corresponding to Y or N answer respectively.
  def prompt_yn(question, args = {})
    args[:valid] = []
    answer = nil

    until answer =~ /^[yn]/i
      answer = prompt(question, args)
    end

    /^n/i.match(answer).nil?
  end

  # Public: Render a spinner on the command line and yield to a block,
  # reporting success if nothing is raised, otherwise reporting failure.
  #
  # message - Message to be displayed describing the task being evaluated.
  # block   - Block to be yielded to determine pass or fail.
  #
  # Returns the result of the yielded block if successful.
  # Raises whatever is raised inside the yielded block.
  def spinner(message, &block)
    success = nil
    result = nil

    pre = "\r#{bold}#{white} [#{reset}"
    post = "#{bold}#{white}] #{reset}#{message}"
    pre_ok = "\r#{bold}#{white} [#{green} ok "
    pre_fail = "\r#{bold}#{white} [#{red}fail"

    thread = Thread.new do
      step = 0
      spin = ["    ", ".   ", "..  ", "... ", "....", " ...", "  ..", "   ."]
      while success.nil?
        print "#{pre}#{spin[step % 8]}#{post}"
        step += 1
        sleep 0.5
      end

      if success
        print "#{pre_ok}#{post}\n"
      else
        print "#{pre_fail}#{post}\n"
      end
    end

    begin
      result = yield
      success = true
      thread.join
      return result
    rescue
      success = false
      thread.join
      raise
    end
  end

  # Public: Generate a reasonably formatted, printable table.
  #
  # options - An Array containing Hash objects which contain desired options:
  #           [{:col1 => val1, :col2 => val2}, {:col1 => val3, :col2 => val4}]
  # labels  - A Hash containing key-value pairs to label each key in options.
  #           (default: nil)
  #
  # Returns a String containing the grid.
  # Raises ArgumentError if options is not an Array which contains at least one
  # element.
  def build_grid(options, labels = nil)
    raise ArgumentError unless options.kind_of?(Array) and !options[0].nil?

    if labels.nil?
      options.unshift(options[0].keys.reduce({}) { |c,e| {e => e.to_s} })
    else
      options.unshift(labels)
    end

    keys = options[0].keys
    max_lengths = keys.reduce({}) { |c,e| c.merge({e => 0}) }

    options.each do |row|
      row.each_key do |key|
        if max_lengths[key] < row[key].to_s.length
          max_lengths[key] = row[key].to_s.length
        end
      end
    end

    # Base width = 3n+1
    grid_width = (max_lengths.length * 3) + 1

    # Construct rule
    grid_rule = "+"
    options[0].each_key { |k| grid_rule << "-" * (max_lengths[k] + 2) + "+" }

    # Construct grid
    grid = ""
    grid << grid_rule

    options.each_with_index do |row, idx|
      grid << "\n|"
      keys.each do |key|
        grid << sprintf(" % #{max_lengths[key]}s |", row[key])
      end

      # Visually separate the labels
      grid << "\n" + grid_rule if idx == 0
    end
    grid << "\n" + grid_rule
  end

  # Minimal documentation provided for the following functions; terminal
  # control sequences are well documented; here we are only providing
  # shorthand.

  # Public: Escape sequence
  #
  # Returns a String containing an escaped terminal control sequence.
  def escape(seq); "\033[#{seq}m"; end

  # Public: Reset terminal control
  #
  # Returns a String the 'reset' terminal control sequence.
  def reset; escape("0"); end

  # Public: Set text bold
  #
  # Returns a String the terminal control sequence to set text bold.
  def bold; escape("1"); end

  # Public: Set text underlined
  #
  # Returns a String the terminal control sequence to set text underlined.
  def underline; escape("4"); end

  # Public: Set text flashing
  #
  # Returns a String the terminal control sequence to set text flashing.
  def annoy; escape("5"); end

  # Public: Set text red
  #
  # Returns a String the terminal control sequence to set text red.
  def red; escape("31"); end

  # Public: Set text green
  #
  # Returns a String the terminal control sequence to set text green.
  def green; escape("32"); end

  # Public: Set text blue
  #
  # Returns a String the terminal control sequence to set text blue.
  def blue; escape("34"); end

  # Public: Set text white
  #
  # Returns a String the terminal control sequence to set text white.
  def white; escape("37"); end
end
