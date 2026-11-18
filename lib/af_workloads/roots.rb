# frozen_string_literal: true

require "digest"
require_relative "error"

module AFWorkloads
  # Resolves the public code checkout and explicitly selected workload store.
  module Roots
    CODE = File.expand_path("../..", __dir__)

    module_function

    # Returns whether the installed code has the public distribution marker.
    def public_distribution?(code = CODE)
      File.file?(File.join(code, "lib/af_workloads/public_distribution.rb"))
    end

    # Returns the existing physical store directory; raises Error for a missing
    # selection or when code and writable storage overlap.
    def data(path, code: CODE)
      raise Error, "select --data-root explicitly" if path.to_s.strip.empty?
      root = File.realpath(path)
      code = File.realpath(code)
      unless File.directory?(root) && root != code && !within?(root, code) && !within?(code, root)
        raise Error, "data root must be an existing directory separate from the code root: #{path}"
      end
      root
    rescue SystemCallError => error
      raise Error, "invalid data root #{path}: #{error.message}"
    end

    # Returns an AFW-owned path under the selected store. Existing symlink
    # components and lexical escapes raise Error, including for future writes.
    def owned(root, path)
      expanded = File.expand_path(path, root)
      raise Error, "path outside data root: #{path}" unless within?(root, expanded)

      current = root
      expanded.delete_prefix(root + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        raise Error, "symlink in data root path: #{current}" if File.symlink?(current)
      end
      expanded
    end

    # Returns whether a normalized absolute path is strictly below a directory.
    def within?(root, path)
      path.start_with?(root.chomp(File::SEPARATOR) + File::SEPARATOR) && path != root
    end

    # Returns the legacy Git revision or the exact public executable tree's
    # identity, including when the distribution is used straight from an archive.
    # Missing or unreadable code files raise Error.
    def generator(code, git_head)
      return git_head.call(code) unless public_distribution?(code)

      paths = Dir.glob(["bin/*", "lib/**/*.rb", "config/**/*", "production_backlog/**/*", "Gemfile.lock"], base: code)
      files = paths.sort.filter_map do |path|
        file = File.join(code, path)
        [path, Digest::SHA256.file(file).hexdigest] if File.file?(file)
      end
      "sha256:#{Digest::SHA256.hexdigest(files.map { |path, hash| "#{hash}  #{path}\n" }.join)}"
    rescue SystemCallError => error
      raise Error, "cannot identify generator: #{error.message}"
    end
  end
end
