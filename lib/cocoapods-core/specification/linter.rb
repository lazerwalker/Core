module Pod
  class Specification

    # The Linter check specifications for errors and warnings.
    #
    # It is designed not only to guarantee the formal functionality of a
    # specification, but also to support the maintenance of sources.
    #
    class Linter

      # @return [Specification] the specification to lint.
      #
      attr_reader :spec

      # @return [Pathname] the path of the `podspec` file where {#spec} is
      #         defined.
      #
      attr_reader :file

      # @param  [Specification, Pathname, String] spec_or_path
      #         the Specification or the path of the `podspec` file to lint.
      #
      def initialize(spec_or_path)
        if spec_or_path.is_a?(Specification)
          @spec = spec_or_path
          @file = @spec.defined_in_file
        else
          @file = Pathname.new(spec_or_path)
          begin
            @spec = Specification.from_file(@file)
          rescue Exception => e
            @spec = nil
            @raise_message = e.message
          end
        end
      end

      # Lints the specification adding a {Result} for any failed check to the
      # {#results} list.
      #
      # @return [Bool] whether the specification passed validation.
      #
      def lint
        @results = []
        if spec
          perform_textual_analysis
          check_required_root_attributes
          run_root_validation_hooks
          perform_all_specs_analysis
        else
          error "The specification defined in `#{file}` could not be loaded." \
            "\n\n#{@raise_message}"
        end
        results.empty?
      end

      #-----------------------------------------------------------------------#

      # !@group Lint results

      public

      # @return [Array<Result>] all the results generated by the Linter.
      #
      attr_reader :results

      # @return [Array<Result>] all the errors generated by the Linter.
      #
      def errors
        @errors ||= results.select { |r| r.type == :error }
      end

      # @return [Array<Result>] all the warnings generated by the Linter.
      #
      def warnings
        @warnings ||= results.select { |r| r.type == :warning }
      end

      #-----------------------------------------------------------------------#

      private

      # !@group Lint steps

      # It reads a podspec file and checks for strings corresponding
      # to features that are or will be deprecated
      #
      # @return [void]
      #
      def perform_textual_analysis
        return unless @file
        text = @file.read
        if text =~ /config\..?os.?/
          error "`config.ios?` and `config.osx?` are deprecated."
        end
        if text =~ /clean_paths/
          error "clean_paths are deprecated (use preserve_paths)."
        end

        all_lines_count = text.lines.count
        comments_lines_count = text.scan(/^\s*#\s+/).length
        comments_ratio = comments_lines_count.fdiv(all_lines_count)
        if comments_lines_count > 20 && comments_ratio > 0.2
          warning "Comments must be deleted."
        end
        if text.lines.first =~ /^\s*#\s+/
          warning "Comments placed at the top of the specification must be " \
            "deleted."
        end
      end

      # Checks that every root only attribute which is required has a value.
      #
      # @return [void]
      #
      def check_required_root_attributes
        attributes = DSL.attributes.values.select(&:root_only?)
        attributes.each do |attr|
          value = spec.send(attr.name)
          next unless attr.required?
          unless value && (!value.respond_to?(:empty?) || !value.empty?)
            if attr.name == :license
              warning("Missing required attribute `#{attr.name}`.")
            else
              error("Missing required attribute `#{attr.name}`.")
            end
          end
        end
      end

      # Runs the validation hook for root only attributes.
      #
      # @return [void]
      #
      def run_root_validation_hooks
        attributes = DSL.attributes.values.select(&:root_only?)
        attributes.each do |attr|
          validation_hook = "_validate_#{attr.name}"
          next unless respond_to?(validation_hook, true)
          value = spec.send(attr.name)
          next unless value
          send(validation_hook, value)
        end
      end

      # Run validations for multi-platform attributes activating .
      #
      # @return [void]
      #
      def perform_all_specs_analysis
        all_specs = [spec, *spec.recursive_subspecs]
        all_specs.each do |current_spec|
          current_spec.available_platforms.each do |platform|
            @consumer = Specification::Consumer.new(current_spec, platform)
            run_all_specs_validation_hooks
            validate_file_patterns
            check_tmp_arc_not_nil
            check_if_spec_is_empty
            check_install_hooks
            @consumer = nil
          end
        end
      end

      # @return [Specification::Consumer] the current consumer.
      #
      attr_accessor :consumer

      # Runs the validation hook for the attributes that are not root only.
      #
      # @return [void]
      #
      def run_all_specs_validation_hooks
        attributes = DSL.attributes.values.reject(&:root_only?)
        attributes.each do |attr|
          validation_hook = "_validate_#{attr.name}"
          next unless respond_to?(validation_hook, true)
          value = consumer.send(attr.name)
          next unless value
          send(validation_hook, value)
        end
      end

      # Runs the validation hook for each attribute.
      #
      # @note   Hooks are called only if there is a value for the attribute as
      #         required attributes are already checked by the
      #         {#check_required_root_attributes} step.
      #
      # @return [void]
      #
      def run_validation_hooks(attributes)

      end

      #-----------------------------------------------------------------------#

      private

      # @!group Root spec validation helpers

      # Performs validations related to the `name` attribute.
      #
      def _validate_name(n)
        if spec.name && file
          acceptable_names = [
            spec.root.name + '.podspec',
            spec.root.name + '.podspec.yaml'
          ]
          names_match = acceptable_names.include?(file.basename.to_s)
          unless names_match
            error "The name of the spec should match the name of the file."
          end

          if spec.root.name =~ /\s/
            error "The name of a spec should not contain whitespace."
          end
        end
      end

      def _validate_version(v)
        if v.to_s.empty?
          error "A version is required."
        elsif v <= Version::ZERO
          error "The version of the spec should be higher than 0."
        end
      end

      # Performs validations related to the `summary` attribute.
      #
      def _validate_summary(s)
        if s.length > 140
          warning "The summary should be a short version of `description` " \
            "(max 140 characters)."
        end
        if s =~ /A short description of/
          warning "The summary is not meaningful."
        end
      end

      # Performs validations related to the `description` attribute.
      #
      def _validate_description(d)
        if d =~ /An optional longer description of/
          warning "The description is not meaningful."
        end
        if d == spec.summary
          warning "The description is equal to the summary."
        end
        if d.length < spec.summary.length
          warning "The description is shorter than the summary."
        end
      end

      # Performs validations related to the `homepage` attribute.
      #
      def _validate_homepage(h)
        if h =~ %r[http://EXAMPLE]
          warning "The homepage has not been updated from default"
        end
      end

      # Performs validations related to the `frameworks` attribute.
      #
      def _validate_frameworks(frameworks)
        if frameworks_invalid?(frameworks)
          error "A framework should only be specified by its name"
        end
      end

      # Performs validations related to the `weak frameworks` attribute.
      #
      def _validate_weak_frameworks(frameworks)
        if frameworks_invalid?(frameworks)
          error "A weak framework should only be specified by its name"
        end
      end

      # Performs validations related to the `libraries` attribute.
      #
      def _validate_libraries(libs)
        if libs.any? { |lib| lib.end_with?('.a', '.dylib') }
          error "A library should only be specified by its name"
        end
      end

      # Performs validations related to the `license` attribute.
      #
      def _validate_license(l)
        type = l[:type]
        if type.nil?
          warning "Missing license type."
        end
        if type && type.gsub(' ', '').gsub("\n", '').empty?
          warning "Invalid license type."
        end
        if type && type =~ /\(example\)/
          error "Sample license type."
        end
      end

      # Performs validations related to the `source` attribute.
      #
      def _validate_source(s)
        if git = s[:git]
          tag, commit = s.values_at(:tag, :commit)
          version = spec.version.to_s

          if git =~ %r[http://EXAMPLE]
            error "Example source."
          end
          if commit && commit.downcase =~ /head/
            error 'The commit of a Git source cannot be `HEAD`.'
          end
          if tag && !tag.include?(version)
            warning 'The version should be included in the Git tag.'
          end

          if version == '0.0.1'
            if commit.nil? && tag.nil?
              error 'Git sources should specify either a commit or a tag.'
            end
          else
            warning 'Git sources should specify a tag.' if tag.nil?
          end
        end

        perform_github_source_checks(s)
      end

      # Performs validations related to github sources.
      #
      def perform_github_source_checks(s)
        supported_domains = [
          'https://github.com',
          'https://gist.github.com',
        ]

        if git = s[:git]
          is_github = git.include?('github.com')
          if is_github
            unless git.end_with?('.git')
              warning "Github repositories should end in `.git`."
            end
            unless supported_domains.find { |domain| git.start_with?(domain) }
              warning "Github repositories should use `https` link."
            end
          end
        end
      end

      #-----------------------------------------------------------------------#

      # @!group All specs validation helpers

      private

      # Performs validations related to the `compiler_flags` attribute.
      #
      def _validate_compiler_flags(flags)
        if flags.join(' ').split(' ').any? { |flag| flag.start_with?('-Wno') }
          warning "Warnings must not be disabled (`-Wno' compiler flags)."
        end
      end

      # Checks the attributes that represent file patterns.
      #
      # @todo Check the attributes hash directly.
      #
      def validate_file_patterns
        attributes = DSL.attributes.values.select(&:file_patterns?)
        attributes.each do |attrb|
          patterns = consumer.send(attrb.name)
          if patterns.is_a?(Hash)
            patterns = patterns.values.flatten(1)
          end
          patterns.each do |pattern|
            if pattern.start_with?('/')
              error "File patterns must be relative and cannot start with a " \
                "slash (#{attrb.name})."
            end
          end
        end
      end

      # @todo remove in 0.18 and switch the default to true.
      #
      def check_tmp_arc_not_nil
        if consumer.requires_arc.nil?
          warning "A value for `requires_arc` should be specified until the " \
            "migration to a `true` default."
        end
      end

      # Check empty subspec attributes
      #
      def check_if_spec_is_empty
        methods = %w[ source_files resources preserve_paths dependencies vendored_libraries vendored_frameworks ]
        empty_patterns = methods.all? { |m| consumer.send(m).empty? }
        empty = empty_patterns && consumer.spec.subspecs.empty?
        if empty
          error "The #{consumer.spec} spec is empty (no source files, " \
            "resources, preserve paths, , vendored_libraries, " \
              "vendored_frameworks dependencies or subspecs)."
        end
      end

      # Check the hooks
      #
      def check_install_hooks
        unless consumer.spec.pre_install_callback.nil?
          warning "The pre install hook of the specification DSL has been " \
            "deprecated, use the `resource_bundles` or the " \
              "`prepare_command` attributes."
        end

        unless consumer.spec.post_install_callback.nil?
          warning "The post install hook of the specification DSL has been " \
            "deprecated, use the `resource_bundles` or the " \
              " `prepare_command` attributes."
        end
      end

      # Returns whether the frameworks are valid
      #
      # @params frameworks [Array<String>]
      # The frameworks to be validated
      #
      # @return [Boolean] true if a framework ends in `.framework`
      #
      def frameworks_invalid?(frameworks)
        frameworks.any? { |framework| framework.end_with?('.framework') }
      end

      #-----------------------------------------------------------------------#

      # !@group Result Helpers

      private

      # Adds an error result with the given message.
      #
      # @param  [String] message
      #         The message of the result.
      #
      # @return [void]
      #
      def error(message)
        add_result(:error, message)
      end

      # Adds an warning result with the given message.
      #
      # @param  [String] message
      #         The message of the result.
      #
      # @return [void]
      #
      def warning(message)
        add_result(:warning, message)
      end

      # Adds a result of the given type with the given message. If there is a
      # current platform it is added to the result. If a result with the same
      # type and the same message is already available the current platform is
      # added to the existing result.
      #
      # @param  [Symbol] type
      #         The type of the result (`:error`, `:warning`).
      #
      # @param  [String] message
      #         The message of the result.
      #
      # @return [void]
      #
      def add_result(type, message)
        result = results.find { |r| r.type == type && r.message == message }
        unless result
          result = Result.new(type, message)
          results << result
        end
        result.platforms << consumer.platform_name if consumer
      end

      #-----------------------------------------------------------------------#

      class Result

        # @return [Symbol] the type of result.
        #
        attr_reader :type

        # @return [String] the message associated with result.
        #
        attr_reader :message

        # @param [Symbol] type    @see type
        # @param [String] message @see message
        #
        def initialize(type, message)
          @type    = type
          @message = message
          @platforms = []
        end

        # @return [Array<Platform>] the platforms where this result was
        #         generated.
        #
        attr_reader :platforms

        # @return [String] a string representation suitable for UI output.
        #
        def to_s
          r = "[#{type.to_s.upcase}] #{message}"
          if platforms != Specification::PLATFORMS
            platforms_names = platforms.uniq.map do |p|
              Platform.string_name(p)
            end
            r << " [#{platforms_names * ' - '}]" unless platforms.empty?
          end
          r
        end
      end

      #-----------------------------------------------------------------------#

    end
  end
end

      # # TODO
      # # Converts the resources file patterns to a hash defaulting to the
      # # resource key if they are defined as an Array or a String.
      # #
      # # @param  [String, Array, Hash] value.
      # #         The value of the attribute as specified by the user.
      # #
      # # @return [Hash] the resources.
      # #
      # def _prepare_deployment_target(deployment_target)
      #   unless @define_for_platforms.count == 1
      #     raise StandardError, "The deployment target must be defined per platform like `s.ios.deployment_target = '5.0'`."
      #   end
      #   Version.new(deployment_target)
      # end

      # # TODO
      # # Converts the resources file patterns to a hash defaulting to the
      # # resource key if they are defined as an Array or a String.
      # #
      # # @param  [String, Array, Hash] value.
      # #         The value of the attribute as specified by the user.
      # #
      # # @return [Hash] the resources.
      # #
      # def _prepare_platform(name_and_deployment_target)
      #   return nil if name_and_deployment_target.nil?
      #   if name_and_deployment_target.is_a?(Array)
      #     name = name_and_deployment_target.first
      #     deployment_target = name_and_deployment_target.last
      #   else
      #     name = name_and_deployment_target
      #     deployment_target = nil
      #   end
      #   unless PLATFORMS.include?(name)
      #     raise StandardError, "Unsupported platform `#{name}`. The available " \
      #       "names are `#{PLATFORMS.inspect}`"
      #   end
      #   Platform.new(name, deployment_target)
      # end
