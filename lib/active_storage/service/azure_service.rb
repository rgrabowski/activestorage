require "active_support/core_ext/numeric/bytes"
require "azure/storage"
require "azure/storage/core/auth/shared_access_signature"

# Wraps the Microsoft Azure Storage Blob Service as a Active Storage service.
# See `ActiveStorage::Service` for the generic API documentation that applies to all services.
class ActiveStorage::Service::AzureService < ActiveStorage::Service
  attr_reader :client, :path, :blobs, :container, :signer

  def initialize(path:, storage_account_name:, storage_access_key:, container:)
    @client = Azure::Storage::Client.create(storage_account_name: storage_account_name, storage_access_key: storage_access_key)
    @signer = Azure::Storage::Core::Auth::SharedAccessSignature.new(storage_account_name, storage_access_key)
    @blobs = client.blob_client
    @container = container
    @path = path
  end

  def upload(key, io, checksum: nil)
    instrument :upload, key, checksum: checksum do
      begin
        blobs.create_block_blob(container, key, io, content_md5: checksum)
      rescue Azure::Core::Http::HTTPError => e
        raise ActiveStorage::IntegrityError
      end
    end
  end

  def download(key)
    if block_given?
      instrument :streaming_download, key do
        stream(key, &block)
      end
    else
      instrument :download, key do
        _, io = blobs.get_blob(container, key)
        io.force_encoding(Encoding::BINARY)
      end
    end
  end

  def delete(key)
    instrument :delete, key do
      begin
        blobs.delete_blob(container, key)
      rescue Azure::Core::Http::HTTPError
        false
      end
    end
  end

  def exist?(key)
    instrument :exist, key do |payload|
      answer = blob_for(key).present?
      payload[:exist] = answer
      answer
    end
  end

  def url(key, expires_in:, disposition:, filename:)
    instrument :url, key do |payload|
      base_url = url_for(key)
      generated_url = signer.signed_uri(URI(base_url), false, permissions: "r",
        expiry: format_expiry(expires_in), content_disposition: "#{disposition}; filename=\"#{filename}\"").to_s

      payload[:url] = generated_url

      generated_url
    end
  end

  def url_for_direct_upload(key, expires_in:, content_type:, content_length:, checksum:)
    instrument :url, key do |payload|
      base_url = url_for(key)
      generated_url = signer.signed_uri(URI(base_url), false, permissions: "rw",
        expiry: format_expiry(expires_in)).to_s

      payload[:url] = generated_url

      generated_url
    end
  end

  def headers_for_direct_upload(key, content_type:, checksum:, **)
    { "Content-Type" => content_type, "Content-MD5" => checksum, "x-ms-blob-type" => "BlockBlob" }
  end

  private
    def url_for(key)
      "#{path}/#{container}/#{key}"
    end

    def blob_for(key)
      blobs.get_blob_properties(container, key)
    rescue Azure::Core::Http::HTTPError
      false
    end

    def format_expiry(expires_in)
      expires_in ? Time.now.utc.advance(seconds: expires_in).iso8601 : nil
    end

    # Reads the object for the given key in chunks, yielding each to the block.
    def stream(key, options = {}, &block)
      blob = blob_for(key)

      chunk_size = 5.megabytes
      offset = 0

      while offset < blob.properties[:content_length]
        _, io = blobs.get_blob(container, key, start_range: offset, end_range: offset + chunk_size - 1)
        yield io
        offset += chunk_size
      end
    end
end
