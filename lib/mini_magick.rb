require "open-uri"
require "stringio"
require "fileutils"

require File.join(File.dirname(__FILE__), '/image_temp_file')

module MiniMagick
  class MiniMagickError < RuntimeError; end

  VERSION = '1.2.3'

  class Image
    attr :path
    attr :tempfile
    attr :output

    # Class Methods
    # -------------
    class <<self
      def from_blob(blob, extension=nil)
        begin
          tempfile = ImageTempFile.new("minimagick#{extension}")
          tempfile.binmode
          tempfile.write(blob)
        ensure
          tempfile.close
        end
        
        return self.new(tempfile.path, tempfile)
      end

      # Use this if you don't want to overwrite the image file
      def from_file(image_path)
        File.open(image_path, "rb") do |f|
          self.from_blob(f.read, File.extname(image_path))
        end
      end
    end

    # Instance Methods
    # ----------------
    def initialize(input_path, tempfile=nil)
      @path = input_path
      @tempfile = tempfile # ensures that the tempfile will stick around until this image is garbage collected.

      # Ensure that the file is an image
      run_command("identify", @path)
    end

    # For reference see http://www.imagemagick.org/script/command-line-options.php#format
    def [](value)
      # Why do I go to the trouble of putting in newlines? Because otherwise animated gifs screw everything up
      case value.to_s
      when "format"
        run_command("identify", "-format", format_option("%m"), @path).split("\n")[0]
      when "height"
        run_command("identify", "-format", format_option("%h"), @path).split("\n")[0].to_i
      when "width"
        run_command("identify", "-format", format_option("%w"), @path).split("\n")[0].to_i
      when "original_at"
        # Get the EXIF original capture as a Time object
        Time.local(*self["EXIF:DateTimeOriginal"].split(/:|\s+/)) rescue nil
      when /^EXIF\:/i
        run_command('identify', '-format', "\"%[#{value}]\"", @path).chop
      else
        run_command('identify', '-format', "\"#{value}\"", @path).split("\n")[0]
      end
    end

    # This is a 'special' command because it needs to change @path to reflect the new extension
    def format(format)
      run_command("mogrify", "-format", format, @path)
      @path = @path.sub(/(\.\w+)?$/, ".#{format}")
      
      raise "Unable to format to #{format}" unless File.exists?(@path)
    end

    # Writes the temporary image that we are using for processing to the output path
    def write(output_path)
      FileUtils.copy_file @path, output_path
      File.chmod(0644, output_path)
      run_command "identify", output_path # Verify that we have a good image
    end

    # Give you raw data back
    def to_blob
      File.read @path
    end
    
    def watermark(mark_file, target)
      run_command('composite', '-watermark', '35%', "#{mark_file}", '-gravity', 'center', target, target )
    end

    def watermark_cross(width, height, target)
      opacity = 'fill-opacity 0.15 stroke-opacity 0.15'
      run_command('convert', @path, '-fill', 'white', '-stroke', 'white', '-strokewidth', '2', '-draw',
                  "#{opacity} line 0,0 #{width},#{height}", '-draw', "#{opacity} line #{width},0 0,#{height}", target )
    end

    def annotate(text, output, size = '24', position = '0x0+10+30')
      run_command('convert', '-pointsize', size, '-annotate', position, text, @path, output )
      #-pointsize 24 -stroke red -fill red -box blue -annotate 0x0+10+30 stillhq.com input.jpg output.jpg      
    end

    def annotate_box(text, output, height = 12)
      width = run_command('identify','-format %w',  @path).strip #TODO is this redundant as we know the preview width before we get here
      width = "#{width}x#{height}"
      run_command('convert', '-background', '#0008', '-fill white', '-gravity center', "-size #{width}",
                  "caption:\"#{text}\"", @path, '+swap', '-gravity', 'south', '-composite', output )
    end

    def top_colors(limit = 10, depth = 4, colors = 32 )
      #c={};Photo.all(:limit => 100).each{|photo| photo.top_colors.each{|col| c[col] = c[col].nil? ? 1 : c[col] + 1}}; c.sort{|a,b| a[1] <=> b[1] }
      out = run_command("convert #{@path} +dither -colors #{colors}  -depth #{depth} -format %c histogram:info:-")
      out.scan(/#[A-F0-9]+/)[0..(limit-1)]
    end
      
    # If an unknown method is called then it is sent through the morgrify program
    # Look here to find all the commands (http://www.imagemagick.org/script/mogrify.php)
    def method_missing(symbol, *args)
      args.push(@path) # push the path onto the end
      run_command("mogrify", "-#{symbol}", *args)
      self
    end

    # You can use multiple commands together using this method
    def combine_options(&block)
      c = CommandBuilder.new
      block.call c
      run_command("mogrify", *c.args << @path)
    end
    def combine_options_convert(&block)
      c = CommandBuilder.new
      block.call c
      run_command("mogrify", *c.args << @path)
    end

    # Check to see if we are running on win32 -- we need to escape things differently
    def windows?
      !(RUBY_PLATFORM =~ /win32/).nil?
    end

    # Outputs a carriage-return delimited format string for Unix and Windows
    def format_option(format)
      windows? ? "#{format}\\n" : "#{format}\\\\n"
    end

    def run_command(command, *args)
      args.collect! do |arg|
        arg = arg.to_s
        arg = %|"#{arg}"| unless (arg =~ /^-|^\+|^caption/) # values quoted because they can contain characters like '>', but don't quote switches          
        arg
      end
      
      RAILS_DEFAULT_LOGGER.debug("Imagick Command: #{command} #{args.join(' ')}")

      @output = `#{command} #{args.join(' ')}`

      if $? != 0
        raise MiniMagickError, "ImageMagick command (#{command} #{args.join(' ')}) failed: Error Given #{$?}"
      else
        @output
      end
    end
  end

  class CommandBuilder
    attr :args

    def initialize
      @args = []
    end

    def method_missing(symbol, *args)
      @args << "-#{symbol}"
      @args += args
    end
    
    def +(value)
      @args << "+#{value}"
    end
  end
end
