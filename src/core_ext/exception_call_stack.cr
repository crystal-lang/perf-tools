struct Exception::CallStack
  def initialize(*, __callstack @callstack : Array(Void*))
  end

  {% unless @type.class.has_method?(:decode_backtrace_frame) %} # Crystal < 1.16.0
    # :nodoc:
    def self.decode_backtrace_frame(ip, show_full_info) : String?
      pc = decode_address(ip)
      file, line_number, column_number = decode_line_number(pc)

      if file && file != "??"
        return if @@skip.includes?(file)

        # Turn to relative to the current dir, if possible
        if current_dir = CURRENT_DIR
          if rel = Path[file].relative_to?(current_dir)
            rel = rel.to_s
            file = rel unless rel.starts_with?("..")
          end
        end

        file_line_column = file
        unless line_number == 0
          file_line_column = "#{file_line_column}:#{line_number}"
          file_line_column = "#{file_line_column}:#{column_number}" unless column_number == 0
        end
      end

      if name = decode_function_name(pc)
        function = name
      elsif frame = decode_frame(ip)
        _, function, file = frame
        # Crystal methods (their mangled name) start with `*`, so
        # we remove that to have less clutter in the output.
        function = function.lchop('*')
      else
        function = "??"
      end

      if file_line_column
        if show_full_info && (frame = decode_frame(ip))
          _, sname, _ = frame
          line = "#{file_line_column} in '#{sname}'"
        else
          line = "#{file_line_column} in '#{function}'"
        end
      else
        if file == "??" && function == "??"
          line = "???"
        else
          line = "#{file} in '#{function}'"
        end
      end

      if show_full_info
        line = "#{line} at 0x#{ip.address.to_s(16)}"
      end

      line
    end
  {% end %}
end
