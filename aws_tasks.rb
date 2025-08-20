#!/usr/bin/env ruby -rpry
# frozen_string_literal: true

require 'aws-sdk-ec2'
require 'aws-sdk-costexplorer'
require 'aws-sdk-s3'
require 'json'
require 'hirb'
require 'pathname'
require 'optparse'
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

  # Starts all stopped instances from the last call to list_instances (with tag filter)
  def start_instances(dry_run: true)
    if @last_response
      instance_ids = @last_response.select { |obj| obj.is_a?(Aws::EC2::Instance) && obj.state.name == 'stopped' }.map(&:id)
      if instance_ids.empty?
        puts 'No stopped instances to start.'
      else
        begin
          @client.start_instances({ instance_ids: instance_ids, dry_run: dry_run })
        rescue Aws::EC2::Errors::DryRunOperation => e
          puts "Nothing Changed: #{e.message}"
        rescue StandardError => e
          puts "Error starting instances: #{e.message}"
        end
      end
    else
      puts "No instances to start.\nPlease run 'list_instances' with a tags filter before starting."
    end
  end

  def stop_instances(dry_run: true)
    if @last_response
      instance_ids = @last_response.select { |obj| obj.is_a?(Aws::EC2::Instance) && obj.state.name == 'running' }.map(&:id)
      if instance_ids.empty?
        puts 'No running instances to stop.'
      else
        begin
          @client.stop_instances({ instance_ids: instance_ids, dry_run: dry_run })
        rescue Aws::EC2::Errors::DryRunOperation => e
          puts "Nothing Changed: #{e.message}"
        rescue StandardError => e
          puts "Error stopping instances: #{e.message}"
        end
      end
    else
      puts "No instances to stop.\nPlease run 'list_instances' with a tags filter before stopping."
    end
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
            rescue Aws::EC2::Errors::DryRunOperation => e
              puts "Nothing Changed: #{e.message}"
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
      fsize = File.size(file_path)
      multipart_threshold = if fsize > 20 * 1024 * 1024
                              fsize / 10
                            elsif fsize > 10 * 1024 * 1024
                              fsize / 5
                            elsif fsize > 5 * 1024 * 1024
                              fsize / 3
                            end
      time_started = Time.now
      progress = proc do |bytes, totals|
        print bytes.map.with_index { |b, i| "#{(100 * b / totals[i]).round(0)}%" }.join(' ') + " Total: #{(100.0 * bytes.sum / totals.sum).round(2)}% #{(bytes.sum / 1024 / (Time.now - time_started)).round(2)} KB/s #{' ' * 20}\r"
      end
      @object.upload_file(file_path, progress_callback: progress, multipart_threshold: multipart_threshold)
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

  def upload(file_path, dry_run: false, no_overwrite: true)
    full_file_path = File.expand_path(file_path)
    object_key = Pathname.new(full_file_path).relative_path_from(Pathname.pwd).to_s
    curr_obj = @bucket.object(object_key)
    if curr_obj.exists? && (no_overwrite || (curr_obj.size == File.size(full_file_path) && curr_obj.etag !~ /.*-\d+/ && curr_obj.etag == AwsStorage.calculate_file_etag(full_file_path)))
      if no_overwrite
        puts "File #{file_path} is already uploaded and no_overwrite is set."
      else
        puts "File #{file_path} is already uploaded and has the same size and ETag."
      end
      return
    end
    puts "#{DateTime.now} Uploading #{file_path} to #{@bucket_name}:#{object_key}..."
    return if dry_run

    object = Aws::S3::Object.new(@bucket_name, object_key, client: @client)
    wrapper = ObjectUploadFileWrapper.new(object)
    return unless wrapper.upload_file(full_file_path)

    puts "#{DateTime.now} File #{file_path} successfully uploaded to #{@bucket_name}:#{object_key}."
  end

  def upload_many(glob_pattern, dry_run: true, no_overwrite: true)
    return unless @bucket

    Dir.glob(glob_pattern).each do |file_path|
      next unless File.file?(file_path)

      upload(file_path, dry_run: dry_run, no_overwrite: no_overwrite)
    end
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

def run_with_args(args)
  options = {
    overwrite: false,
    tags: {}
  }
  command = args[0]
  valid_command = %w[s3 ec2 cost].include?(command)
  OptionParser.new(args[1..]) do |opts| # rubocop:disable Metrics/BlockLength
    opts.banner = 'Usage: aws_tasks.rb [command] [options]'
    opts.separator 'Commands: s3 | ec2 | cost' unless valid_command

    case command
    when 's3'
      opts.on('-b', '--bucket BUCKET', 'Specify the S3 bucket name') do |bucket|
        options[:bucket] = bucket
      end
      opts.on('-g', '--glob GLOB', 'Glob pattern to filter objects in the bucket') do |glob|
        options[:glob] = glob
      end
      opts.on('-l', '--list', 'List objects in the bucket') do
        options[:list] = true
      end

      opts.on('-u', '--upload FILE', 'Upload a file to the bucket') do |file|
        options[:upload] = file
      end
      opts.on('-m', '--upload-many GLOB', 'Upload many files matching a glob pattern to the bucket') do |glob|
        options[:upload_many] = glob
      end
      opts.on('-o', '--overwrite', 'Overwrite existing files') do
        options[:overwrite] = true
      end

      opts.on('-d', '--delete FILE', 'Delete a file from the bucket') do |file|
        options[:delete] = file
      end
    when 'ec2'
      opts.on('-n', '--names a,b,c', Array, 'Specify EC2 instance names') do |names|
        options[:tags].merge!({ Name: names.map(&:strip) })
      end
      opts.on('--start', 'Start EC2 instances') do
        options[:start] = true
      end
      opts.on('--stop', 'Stop EC2 instances') do
        options[:stop] = true
      end
    end

    if valid_command
      opts.on('-r', '--region REGION', 'AWS region to use (default is env var AWS_REGION or ~/.aws/config settings)') do |region|
        options[:region] = region
      end
      opts.on('--dry-run', 'Perform a dry run (no changes will be made)') do
        options[:dry_run] = true
      end
    end
    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit
    end
  end.parse!(args)

  return unless valid_command

  case command
  when 's3'
    if options[:bucket].nil?
      puts 'Bucket name is required for S3 operations.'
      return
    end
    s = if options[:region]
          AwsStorage.new(options[:bucket], region: options[:region])
        else
          AwsStorage.new(options[:bucket])
        end
    # Now you can use the options hash to determine what to do
    if options[:list]
      s.list(options[:glob])
    elsif options[:upload]
      s.upload(options[:upload], dry_run: options[:dry_run], no_overwrite: !options[:overwrite])
    elsif options[:upload_many]
      s.upload_many(options[:upload_many], dry_run: options[:dry_run], no_overwrite: !options[:overwrite])
    elsif options[:delete]
      s.delete(options[:delete], dry_run: options[:dry_run])
    end
  when 'ec2'
    aws = if options[:region]
            AwsTasks.new(region: options[:region])
          else
            AwsTasks.new
          end
    if options[:tags].empty?
      aws.list_instances
    else
      aws.list_instances(options[:tags])
    end
    aws.start_instances(dry_run: options[:dry_run]) if options[:start]
    aws.stop_instances(dry_run: options[:dry_run]) if options[:stop]
  when 'cost'
    aws = if options[:region]
            AwsTasks.new(region: options[:region])
          else
            AwsTasks.new
          end
    aws.cost_report
  end
end

# if run with pry: `ruby -rpry script`
if $PROGRAM_NAME == __FILE__
  if defined?(Pry) && ARGV.count.zero?
    binding.pry # rubocop:disable Lint/Debugger
  else
    run_with_args(ARGV)
  end
end
