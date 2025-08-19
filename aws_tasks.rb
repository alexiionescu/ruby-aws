#!/usr/bin/env ruby -rpry
# frozen_string_literal: true

require 'aws-sdk-ec2'
require 'aws-sdk-costexplorer'
require 'aws-sdk-s3'
require 'json'
require 'hirb'
require 'pathname'
Hirb.enable

# This class provides methods to interact with AWS EC2 instances and volumes.
# It uses the AWS SDK for Ruby to perform operations like listing instances,
# listing volumes, and modifying volume attributes.
# Examples: https://github.com/awsdocs/aws-doc-sdk-examples/tree/main/ruby/example_code/ec2
class AwsTasks
  # @!visibility private
  # @return [Aws::EC2::Client] The AWS EC2 client used for API calls.
  # @return [Aws::EC2::Resource] The AWS EC2 resource used for resource-oriented operations.
  # @return [Array<Object>] The last response from an operation that returned Aws objects (Instances, Volumes, etc.).
  attr_accessor :client, :ec2_resource, :last_response, :ce

  def initialize(**options)
    @client = Aws::EC2::Client.new(**options)
    @ec2_resource = Aws::EC2::Resource.new(client: @client)
    @ce = Aws::CostExplorer::Client.new(**options)
    puts "Using AWS region: #{@client.config.region}" if @client.config.region
  end

  # Filters the response based on the provided tags.
  # @param response [Array<Object>] The response to filter.
  # @param tags [Hash] The tags to filter by.
  # @return [Array<Object>] The filtered response.
  def self.filter_response(response, tags)
    return response if tags.empty?

    response.select do |instance|
      instance.tags.any? do |tag|
        tags.any? do |k, v|
          k.to_s.casecmp(tag.key.to_s).zero? && (
            v.is_a?(Array) ? v.include?(tag.value) : tag.value == v.to_s
          )
        end
      end
    end
  end

  # Lists all EC2 instances (optional filters them by tags).
  #
  # @param tags [Hash<String, String|Array<String>>] Optional tags to filter the instances.
  def list_instances(tags = {})
    response = @ec2_resource.instances
    if response.count.zero?
      puts 'No instances found.'
    else
      response = AwsTasks.filter_response(response, tags)
      puts Hirb::Helpers::Table.render(
        response.map { |instance|
          { id: instance.id, state: instance.state.name, tags: instance.tags.map do |tag|
            "#{tag.key}: #{tag.value}"
          end.join(', ') || 'NoTags' }
        }
      )
      unless tags.empty?
        @last_response = response
        @last_response.count
      end
    end
  rescue StandardError => e
    puts "Error getting information about instances: #{e.message}"
  end

  # Lists all EC2 volumes (optional filters them by tags).
  #
  # @param tags [Hash<String, String|Array<String>>] Optional tags to filter the volumes.
  def list_volumes(tags = {})
    response = @ec2_resource.volumes
    if response.count.zero?
      puts 'No volumes found.'
    else
      response = AwsTasks.filter_response(response, tags)
      puts Hirb::Helpers::Table.render(
        response.map do |volume|
          {
            id: volume.id,
            state: volume.state,
            attached: volume.attachments.map(&:instance_id).join(', ') || 'NoAttachments',
            size: volume.size,
            iops: volume.iops,
            throughput: volume.throughput,
            volume_type: volume.volume_type,
            tags: volume.data.tags.map { |tag| "#{tag.key}: #{tag.value}" }.join(', ') || 'NoTags'
          }
        end,
        fields: %i[id state attached size iops throughput volume_type tags]
      )
    end
    unless tags.empty?
      @last_response = response
      @last_response.count
    end
  rescue StandardError => e
    puts "Error getting information about volumes: #{e.message}"
  end

  # Modifies the volume attributes (type and IOPS) of the last listed volumes (with tag filter)
  #
  # @param volume_type [String] The new volume type (gp2, gp3, etc.)
  # @param iops [Integer] The new IOPS value.
  # @param dry_run [Boolean] Whether to perform a dry run (default: true).
  def modify_volumes(volume_type: nil, iops: nil, dry_run: true)
    modified_count = 0
    if @last_response
      @last_response.each do |volume|
        if volume.is_a?(Aws::EC2::Volume)
          # Modify the volume as needed
          if (volume_type && volume_type != volume.volume_type) || (iops && volume.iops != iops)
            begin
              puts "Modifying volume: #{volume.id} #{dry_run ? '(dry run)' : ''} with type: #{volume_type}, iops: #{iops}"
              @client.modify_volume({ dry_run: dry_run, volume_id: volume.id, volume_type: volume_type, iops: iops })
              modified_count += 1
            rescue StandardError => e
              puts "Error modifying volume #{volume.class} : #{volume.id}: #{e.message}"
            end
          end
        else
          puts "Skipping non-volume object: #{volume.id}.\nPlease run 'list_volumes' with a tags filter before modifying."
        end
      end
    else
      puts "No volumes to modify.\nPlease run 'list_volumes' with a tags filter before modifying."
    end
    modified_count
  end

  def cost_report(regions: [])
    regions = [@ce.config.region] if regions.empty?
    response = @ce.get_cost_and_usage(
      time_period: {
        start: (Date.today - 30).strftime('%Y-%m-%d'),
        end: Date.today.strftime('%Y-%m-%d')
      },
      filter: {
        dimensions: {
          key: 'REGION',
          values: regions
        }
      },
      granularity: 'DAILY',
      group_by: [
        {
          key: 'USAGE_TYPE',
          type: 'DIMENSION'
        }
      ],
      metrics: ['UnblendedCost']
    )
    puts Hirb::Helpers::Table.render(
      response.results_by_time
      .flat_map do |result|
        result.groups
        .select { |group| group.metrics['UnblendedCost'].amount.to_f.round(2).positive? }
        .map do |group|
          {
            date: result.time_period.start,
            usage_type: group.keys.first,
            cost: group.metrics['UnblendedCost'].amount.to_f.round(2)
          }
        end
      end,
      fields: %i[date usage_type cost]
    )
  end
end

# Wraps Amazon S3 bucket actions.
class AwsStorage
  # @!visibility private
  # @return [String] The name of the S3 bucket.
  # @return [Aws::S3::Client] The AWS S3 client used for API calls.
  attr_reader :bucket_name, :client, :bucket

  # Initializes the AwsStorage instance with the specified bucket name and options.
  #
  # @param bucket_name [String] The name of the S3 bucket.
  # @param options [Hash] Additional options for the AWS S3 client (region,credentials, etc.)
  def initialize(bucket_name, **options)
    @bucket_name = bucket_name
    @client = Aws::S3::Client.new(**options)
    puts "Using AWS region: #{@client.config.region}" if @client.config.region
    select_bucket(bucket_name)
  end

  def select_bucket(bucket_name)
    @bucket_name = bucket_name
    begin
      # Check if the bucket exists
      @client.head_bucket(bucket: @bucket_name)
      puts "Bucket '#{@bucket_name}' exists."
      @bucket = Aws::S3::Bucket.new(@bucket_name, client: @client)
    rescue Aws::S3::Errors::NotFound
      puts "Bucket '#{@bucket_name}' does not exist."
    rescue Aws::S3::Errors::Forbidden
      puts "Bucket '#{@bucket_name}' exists but you don't have access to it."
    rescue Aws::S3::Errors::Http301Error => e
      puts "Bucket '#{@bucket_name}' exists but is not in the expected region. #{e.data.region ? "Expected region: #{e.data.region}" : 'Unknown'}"
    rescue StandardError => e
      puts "An error occurred: #{e.message}"
    end
  end

  def self.size_human_readable(size_bytes)
    if size_bytes < 1024
      "#{size_bytes} B"
    elsif size_bytes < 1024 * 1024
      "#{(size_bytes / 1024.0).round(1)} KB"
    elsif size_bytes < 1024 * 1024 * 1024
      "#{(size_bytes / 1024.0 / 1024.0).round(2)} MB"
    else
      "#{(size_bytes / 1024.0 / 1024.0 / 1024.0).round(3)} GB"
    end
  end

  def self.calculate_file_etag(file_path)
    return 'NoETag' unless File.exist?(file_path)

    # Calculate the ETag for the file
    digest = Digest::MD5.file(file_path).hexdigest
    "\"#{digest}\""
  rescue StandardError => e
    "LocalETagError: #{e.message}"
  end

  # uploads helper class for S3 object
  class ObjectUploadFileWrapper
    attr_reader :object

    # @param object [Aws::S3::Object] An existing Amazon S3 object.
    def initialize(object)
      @object = object
    end

    # Uploads a file to an Amazon S3 object by using a managed uploader.
    #
    # @param file_path [String] The path to the file to upload.
    # @return [Boolean] True when the file is uploaded; otherwise false.
    def upload_file(file_path)
      @object.upload_file(file_path)
      true
    rescue Aws::Errors::ServiceError => e
      puts "Couldn't upload file #{file_path} to #{@object.key}. Here's why: #{e.message}"
      false
    end
  end

  # Bucket List Helper
  class BucketListObjectsWrapper
    attr_reader :bucket

    # @param bucket [Aws::S3::Bucket] An existing Amazon S3 bucket.
    def initialize(bucket)
      @bucket = bucket
    end

    # Lists object in a bucket.
    #
    # @param glob_pattern [String, nil] A glob pattern to filter object keys (S3 paths).
    # @param max_objects [Integer] The maximum number of objects to list (default: 100).
    # @return number of objects listed.
    def list_objects(glob_pattern = nil, max_objects = 100, local_etag: false)
      objs = @bucket.objects.select { |obj| glob_pattern.nil? || File.fnmatch(glob_pattern, obj.key, File::FNM_EXTGLOB) }
                    .take(max_objects)
                    .map do |obj|
        {
          name: obj.key,
          size: obj.size,
          modified: obj.last_modified,
          etag: obj.etag || 'NoETag',
          local_etag: if local_etag
                        if obj.etag =~ /.*-\d+/
                          'Multipart'
                        else
                          AwsStorage.calculate_file_etag(obj.key) == obj.etag ? 'Match' : 'NoMatch'
                        end
                      else
                        'NotChecked'
                      end
        }
      end
      puts Hirb::Helpers::Table.render(
        objs,
        fields: %i[name size modified etag local_etag],
        filters: { size: ->(size) { AwsStorage.size_human_readable(size) } }
      )
      objs.size
    rescue Aws::Errors::ServiceError => e
      puts "Couldn't list objects in bucket #{bucket.name}. Here's why: #{e.message}"
      0
    end
  end

  def upload(file_path)
    full_file_path = File.expand_path(file_path)
    object_key = Pathname.new(full_file_path).relative_path_from(Pathname.pwd).to_s
    curr_obj = @bucket.object(object_key)
    if curr_obj.exists? && curr_obj.size == File.size(full_file_path) && curr_obj.etag !~ /.*-\d+/ && curr_obj.etag == AwsStorage.calculate_file_etag(full_file_path)
      puts "File #{file_path} is already up-to-date."
      return
    end

    object = Aws::S3::Object.new(@bucket_name, object_key, client: @client)
    wrapper = ObjectUploadFileWrapper.new(object)
    return unless wrapper.upload_file(full_file_path)

    puts "File #{file_path} successfully uploaded to #{@bucket_name}:#{object_key}."
  end

  def list(glob_pattern = nil, max_objects = 100, local_etag: false)
    return unless @bucket

    wrapper = BucketListObjectsWrapper.new(@bucket)
    wrapper.list_objects(glob_pattern, max_objects, local_etag: local_etag)
  end

  def delete(name)
    @client.delete_object(bucket: @bucket_name, key: name)
  end

  def delete_many(glob_pattern)
    return unless @bucket

    objs = @bucket.objects.select { |obj| glob_pattern.nil? || File.fnmatch(glob_pattern, obj.key, File::FNM_EXTGLOB) }
    objs.each do |obj|
      print "Are you sure you want to delete #{obj.key}? (y/N) "
      confirmation = gets.chomp
      if confirmation.downcase == 'y'
        @client.delete_object(bucket: @bucket_name, key: obj.key)
        puts "#{obj.key} has been deleted."
      else
        puts "#{obj.key} was not deleted."
      end
    end
  end
end

# if run with pry: `ruby -rpry script`
if defined?(Pry) && ($PROGRAM_NAME == __FILE__)
  binding.pry # rubocop:disable Lint/Debugger
end
