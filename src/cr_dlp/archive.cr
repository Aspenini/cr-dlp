module CrDlp
  class ArchiveStatus < SidecarValue
    getter skipped : Bool

    def initialize(@skipped : Bool)
    end
  end

  class DownloadArchive
    getter path : String
    getter entries : Set(String)

    def initialize(@path : String)
      @entries = Set(String).new
      load
    end

    def self.id(info : Info) : String?
      video_id = info.string?("id")
      extractor = info.string?("extractor_key") || info.string?("ie_key")
      return unless video_id && extractor
      "#{extractor.downcase} #{video_id}"
    end

    def includes?(info : Info) : Bool
      identifiers = [] of String
      if identifier = self.class.id(info)
        identifiers << identifier
      end
      info.array?("_old_archive_ids").try do |old_ids|
        old_ids.each do |old_id|
          if value = old_id.as_s?
            identifiers << value
          end
        end
      end
      identifiers.any? { |identifier| @entries.includes?(identifier) }
    end

    def record(info : Info)
      identifier = self.class.id(info) ||
                   raise DownloadError.new("Unable to determine download archive ID")
      return if @entries.includes?(identifier)

      File.open(@path, "a+") do |file|
        file.flock_exclusive do
          file.rewind
          current = file.each_line.map(&.strip).reject(&.empty?).to_set
          unless current.includes?(identifier)
            file.seek(0, IO::Seek::End)
            file.puts(identifier)
            file.flush
          end
          @entries.concat(current)
          @entries << identifier
        end
      end
    rescue error : DownloadError
      raise error
    rescue error
      raise DownloadError.new("Unable to write download archive #{@path}: #{error.message}", cause: error)
    end

    private def load
      return unless File.exists?(@path)
      File.open(@path, "r") do |file|
        file.flock_shared do
          file.each_line do |line|
            entry = line.strip
            @entries << entry unless entry.empty?
          end
        end
      end
    rescue error
      raise DownloadError.new("Unable to read download archive #{@path}: #{error.message}", cause: error)
    end
  end
end
