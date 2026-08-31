# frozen_string_literal: true

module JsonDb
  module Storage
    # Writes a file so that readers only ever observe the complete old content or
    # the complete new content -- never a partially written document.
    #
    # The content is streamed into a uniquely named +.tmp+ file **inside the target
    # directory** (so that the final +rename+ stays on one filesystem and is therefore
    # atomic), flushed and +fsync+ed, and only then renamed over the destination.
    # The directory itself is fsynced afterwards so that the rename survives a power
    # loss, not just a process crash.
    module AtomicWriter
      # Permissions for freshly created record files: rw-r--r--.
      FILE_MODE = 0o644

      class << self
        # @param path [String] final destination of the document
        # @param content [String] the complete file content
        # @param mode [Integer] permission bits for the created file
        # @return [Integer] number of bytes written
        def write(path, content, mode: FILE_MODE)
          dir = File.dirname(path)
          FileUtils.mkdir_p(dir)

          tmp_path = tmp_path_for(path)
          bytes = 0

          begin
            File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, mode) do |file|
              bytes = file.write(content)
              file.flush
              file.fsync
            end

            File.rename(tmp_path, path)
            tmp_path = nil
          ensure
            # Only reached when the write or the rename blew up; never leave litter behind.
            silently_unlink(tmp_path) if tmp_path
          end

          fsync_directory(dir)
          bytes
        end

        # Removes +path+ and fsyncs the directory so the unlink is durable.
        # @return [Boolean] true when a file was actually removed
        def delete(path)
          return false unless File.exist?(path)

          File.unlink(path)
          fsync_directory(File.dirname(path))
          true
        rescue Errno::ENOENT
          false
        end

        private

        # Unique per process *and* per thread so concurrent writers never collide on
        # the temporary file, only on the (atomic) rename.
        def tmp_path_for(path)
          File.join(
            File.dirname(path),
            format("%<name>s.%<pid>d.%<rand>s.tmp",
                   name: File.basename(path),
                   pid: Process.pid,
                   rand: SecureRandom.hex(6))
          )
        end

        def silently_unlink(path)
          File.unlink(path)
        rescue SystemCallError
          nil
        end

        # Not every platform/filesystem lets us open a directory for fsync; a failure
        # here costs durability guarantees, never correctness, so it is not fatal.
        def fsync_directory(dir)
          File.open(dir) { |handle| handle.fsync }
          true
        rescue SystemCallError, NotImplementedError
          false
        end
      end
    end
  end
end
