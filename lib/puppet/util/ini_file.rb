# frozen_string_literal: true

require File.expand_path('external_iterator', __dir__)
require File.expand_path('ini_file/section', __dir__)

module Puppet::Util # rubocop:disable Style/ClassAndModuleChildren
  #
  # ini_file.rb
  #
  class IniFile
    def initialize(path, key_val_separator = ' = ', section_prefix = '[', section_suffix = ']',
                   indent_char = ' ', indent_width = nil)

      k_v_s = (key_val_separator =~ %r{^\s+$}) ? ' ' : key_val_separator.strip

      @section_prefix = section_prefix
      @section_suffix = section_suffix
      @indent_char = indent_char
      @indent_width = indent_width&.to_i

      @section_regex = section_regex
      @setting_regex = %r{^(\s*)([^#;\s]|[^#;\s].*?[^\s#{k_v_s}])(\s*#{k_v_s}[ \t]*)(.*)\s*$}
      @commented_setting_regex = %r{^(\s*)[#;]+(\s*)(.*?[^\s#{k_v_s}])(\s*#{k_v_s}[ \t]*)(.*)\s*$}

      @path = path
      @key_val_separator = key_val_separator
      @section_names = []
      @sections_hash = {}
      parse_file
    end

    def section_regex
      # Only put in prefix/suffix if they exist
      r_string = '^\s*'
      r_string += Regexp.escape(@section_prefix)
      r_string += '(.*)'
      r_string += Regexp.escape(@section_suffix)
      r_string += '\s*$'
      %r{#{r_string}}
    end

    attr_reader :section_names

    def get_settings(section_name)
      section = @sections_hash[section_name]
      section.setting_names.each_with_object({}) do |setting, result|
        result[setting] = section.get_value(setting)
      end
    end

    def section?(section_name)
      @sections_hash.key?(section_name)
    end

    def get_value(section_name, setting)
      @sections_hash[section_name].get_value(setting) if @sections_hash.key?(section_name)
    end

    def set_value(*args)
      case args.size
      when 1
        section_name = args[0]
      when 3
        # Backwards compatible set_value function, See MODULES-5172
        (section_name, setting, value) = args
      when 4
        (section_name, setting, separator, value) = args
      end

      complete_setting = {
        setting: setting,
        separator: separator,
        value: value
      }
      add_section(Section.new(section_name, nil, nil, nil, nil)) unless @sections_hash.key?(section_name)

      section = @sections_hash[section_name]

      if section.existing_setting?(setting)
        update_line(section, setting, value)
        section.update_existing_setting(setting, value)
      elsif find_commented_setting(section, setting)
        # So, this stanza is a bit of a hack.  What we're trying
        # to do here is this: for settings that don't already
        # exist, we want to take a quick peek to see if there
        # is a commented-out version of them in the section.
        # If so, we'd prefer to add the setting directly after
        # the commented line, rather than at the end of the section.

        # If we get here then we found a commented line, so we
        # call "insert_inline_setting_line" to update the lines array
        insert_inline_setting_line(find_commented_setting(section, setting), section, complete_setting)

        # Then, we need to tell the setting object that we hacked
        # in an inline setting
        section.insert_inline_setting(setting, value)

        # Finally, we need to update all of the start/end line
        # numbers for all of the sections *after* the one that
        # was modified.
        section_index = @section_names.index(section_name)
        increment_section_line_numbers(section_index + 1)
      elsif !setting.nil? || !value.nil?
        section.set_additional_setting(setting, value)
      end
    end

    def remove_setting(section_name, setting)
      section = @sections_hash[section_name]
      return unless section.existing_setting?(setting)

      # If the setting is found, we have some work to do.
      # First, we remove the line from our array of lines:
      remove_line(section, setting)

      # Then, we need to tell the setting object to remove
      # the setting from its state:
      section.remove_existing_setting(setting)

      # Finally, we need to update all of the start/end line
      # numbers for all of the sections *after* the one that
      # was modified.
      section_index = @section_names.index(section_name)
      decrement_section_line_numbers(section_index + 1)

      return unless section.empty?

      # By convention, it's time to remove this newly emptied out section
      lines.delete_at(section.start_line)
      decrement_section_line_numbers(section_index + 1)
      @section_names.delete_at(section_index)
      @sections_hash.delete(section.name)
    end

    def save
      global_empty = @sections_hash[''].empty? && @sections_hash[''].additional_settings.empty?
      File.open(@path, 'w') do |fh|
        @section_names.each_index do |index|
          name = @section_names[index]

          section = @sections_hash[name]

          # We need a buffer to cache lines that are only whitespace
          whitespace_buffer = []

          if section.new_section? && !section.global?
            fh.puts('') if (index == 1 && !global_empty) || index > 1

            fh.puts("#{@section_prefix}#{section.name}#{@section_suffix}")
          end

          unless section.new_section?
            # write all of the pre-existing lines
            (section.start_line..section.end_line).each do |line_num|
              line = lines[line_num]

              # We buffer any lines that are only whitespace so that
              # if they are at the end of a section, we can insert
              # any new settings *before* the final chunk of whitespace
              # lines.
              if line.match?(%r{^\s*$})
                whitespace_buffer << line
              else
                # If we get here, we've found a non-whitespace line.
                # We'll flush any cached whitespace lines before we
                # write it.
                flush_buffer_to_file(whitespace_buffer, fh)
                fh.puts(line)
              end
            end
          end

          # write new settings, if there are any
          section.additional_settings.each_pair do |key, value|
            fh.puts("#{@indent_char * (@indent_width || section.indentation || 0)}#{key}#{@key_val_separator}#{value}")
          end

          if !whitespace_buffer.empty?
            flush_buffer_to_file(whitespace_buffer, fh)
          elsif section.new_section? && !section.additional_settings.empty? && (index < @section_names.length - 1)
            # We get here if there were no blank lines at the end of the
            # section.
            #
            # If we are adding a new section with a new setting,
            # and if there are more sections that come after this one,
            # we'll write one blank line just so that there is a little
            # whitespace between the sections.
            # if (section.end_line.nil? &&
            fh.puts('')
          end
        end
      end
    end

    private

    def add_section(section)
      @sections_hash[section.name] = section
      @section_names << section.name
    end

    def parse_file
      line_iter = create_line_iter

      # We always create a "global" section at the beginning of the file, for
      # anything that appears before the first named section.
      section = read_section('', 0, line_iter)
      add_section(section)
      line, line_num = line_iter.next

      while line
        if (match = @section_regex.match(line))
          section = read_section(match[1], line_num, line_iter)
          add_section(section)
        end
        line, line_num = line_iter.next
      end
    end

    def read_section(name, start_line, line_iter)
      settings = {}
      end_line_num = start_line
      min_indentation = nil
      empty = true
      loop do
        line, line_num = line_iter.peek
        if line_num.nil? || @section_regex.match(line)
          # the global section always exists, even when it's empty;
          # when it's empty, we must be sure it's thought of as new,
          # which is signalled with a nil ending line
          end_line_num = nil if name == '' && empty
          return Section.new(name, start_line, end_line_num, settings, min_indentation)
        end
        if (match = @setting_regex.match(line))
          settings[match[2]] = match[4]
          indentation = match[1].length
          min_indentation = [indentation, min_indentation || indentation].min
        end
        end_line_num = line_num
        empty = false
        line_iter.next
      end
    end

    def update_line(section, setting, value)
      (section.start_line..section.end_line).each do |line_num|
        next unless (match = @setting_regex.match(lines[line_num]))

        lines[line_num] = "#{match[1]}#{match[2]}#{match[3]}#{value}" if match[2] == setting
      end
    end

    def remove_line(section, setting)
      (section.start_line..section.end_line).each do |line_num|
        next unless (match = @setting_regex.match(lines[line_num]))

        lines.delete_at(line_num) if match[2] == setting
      end
    end

    def create_line_iter
      ExternalIterator.new(lines)
    end

    def lines
      @lines ||= IniFile.readlines(@path)
    end

    # This is mostly here because it makes testing easier--we don't have
    #  to try to stub any methods on File.
    def self.readlines(path) # rubocop:disable Lint/IneffectiveAccessModifier : Attempting to change breaks tests
      # If this type is ever used with very large files, we should
      #  write this in a different way, using a temp
      #  file; for now assuming that this type is only used on
      #  small-ish config files that can fit into memory without
      #  too much trouble.
      File.file?(path) ? File.readlines(path) : []
    end

    # This utility method scans through the lines for a section looking for
    # commented-out versions of a setting.  It returns `nil` if it doesn't
    # find one.  If it does find one, then it returns a hash containing
    # two keys:
    #
    #   :line_num - the line number that contains the commented version
    #               of the setting
    #   :match    - the ruby regular expression match object, which can
    #               be used to mimic the whitespace from the comment line
    def find_commented_setting(section, setting)
      return nil if section.new_section?

      (section.start_line..section.end_line).each do |line_num|
        next unless (match = @commented_setting_regex.match(lines[line_num]))
        return { match: match, line_num: line_num } if match[3] == setting
      end
      nil
    end

    # This utility method is for inserting a line into the existing
    # lines array.  The `result` argument is expected to be in the
    # format of the return value of `find_commented_setting`.
    def insert_inline_setting_line(result, section, complete_setting)
      line_num = result[:line_num]
      s = complete_setting
      lines.insert(line_num + 1, "#{@indent_char * (@indent_width || section.indentation || 0)}#{s[:setting]}#{s[:separator]}#{s[:value]}")
    end

    # Utility method; given a section index (index into the @section_names
    # array), decrement the start/end line numbers for that section and all
    # all of the other sections that appear *after* the specified section.
    def decrement_section_line_numbers(section_index)
      @section_names[section_index..(@section_names.length - 1)].each do |name|
        section = @sections_hash[name]
        section.decrement_line_nums
      end
    end

    # Utility method; given a section index (index into the @section_names
    # array), increment the start/end line numbers for that section and all
    # all of the other sections that appear *after* the specified section.
    def increment_section_line_numbers(section_index)
      @section_names[section_index..(@section_names.length - 1)].each do |name|
        section = @sections_hash[name]
        section.increment_line_nums
      end
    end

    def flush_buffer_to_file(buffer, file)
      return if buffer.empty?

      buffer.each { |l| file.puts(l) }
      buffer.clear
    end
  end
end
