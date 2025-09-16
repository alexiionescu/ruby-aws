#!/usr/bin/env ruby
# frozen_string_literal: true

require 'aws-sdk-ec2'
require 'aws-sdk-costexplorer'
require 'aws-sdk-s3'
require 'json'
require 'hirb'
require 'pathname'
require 'optparse'
require 'tty-cursor'
require 'rainbow'
require 'ruby-progressbar'
require 'yaml'
require 'logger'
Hirb.enable

VALID_VOLUME_TYPES = %w[standard gp2 gp3 io1 io2 st1 sc1].freeze

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
    @logger = Logger.new(options.delete(:log_file) || $stdout)
    @logger.level = options.delete(:log_level) || Logger::WARN
    puts "Logger level set to #{@logger.level}" if @logger.level != Logger::WARN

    @client = Aws::EC2::Client.new(**options)
    @ec2_resource = Aws::EC2::Resource.new(client: @client)
    @ce = Aws::CostExplorer::Client.new(**options)
    puts "AwsTasks: Using region: #{Rainbow(@client.config.region).orange}" if @client.config.region
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
            v.is_a?(Array) ? v.any? { |val| /#{val}/ =~ tag.value } : /#{v}/ =~ tag.value
          )
        end
      end
    end
  end

  def add_tags(resource_id, tags = {}, dry_run: true)
    @client.create_tags({
                          resources: [resource_id],
                          tags: tags.map { |k, v| { key: k.to_s, value: v.is_a?(Array) ? v.first.to_s : v.to_s } },
                          dry_run: dry_run
                        })
  rescue Aws::EC2::Errors::DryRunOperation => e
    puts "Nothing Changed: #{e.message}"
  rescue StandardError => e
    puts "Error adding tags: #{e.message}"
  end

  def list_add_tags(tags = {}, dry_run: true)
    if @last_response
      @last_response.each do |obj|
        add_tags(obj.id, tags, dry_run: dry_run) unless obj.id.nil?
      end
    else
      puts "No resources to add tags to.\nPlease run 'list_*' with a tag filtering param before adding tags."
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
          res = @client.start_instances({ instance_ids: instance_ids, dry_run: dry_run })
          puts Hirb::Helpers::Table.render(res.starting_instances.map do |i|
            { id: i.instance_id, current_state: i.current_state.name }
          end)
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
          res = @client.stop_instances({ instance_ids: instance_ids, dry_run: dry_run })
          puts Hirb::Helpers::Table.render(res.stopping_instances.map do |i|
            { id: i.instance_id, current_state: i.current_state.name }
          end)
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

  def list_reservations
    reservations = Hash.new(0)
    instances = Hash.new(0)
    @client.describe_reserved_instances(filters: [{ name: 'state', values: ['active'] }]).reserved_instances.each do |ri|
      # type = if ri.product_description =~ /VPC/
      #          "ec2:#{ri.instance_type}:vpc"
      #        else
      #          "ec2:#{ri.instance_type}:#{ri.availability_zone || 'none'}"
      #        end
      @logger.debug("Found reservation: #{ri.instance_type} x #{ri.instance_count} (#{ri.availability_zone || 'none'})")
      reservations[ri.instance_type.to_s] += ri.instance_count
    end

    @client.describe_instances(filters: [{ name: 'instance-state-name', values: ['running'] }]).reservations.each do |r|
      r.instances.each do |i|
        # type = if i.vpc_id.nil?
        #          "ec2:#{i.instance_type}:#{i.placement.availability_zone}"
        #        else
        #          "ec2:#{i.instance_type}:vpc"
        #        end
        # type += ":#{i.tags.find { |tag| tag.key == 'Name' }&.value || 'unnamed'}"
        @logger.debug("Found running instance: #{i.instance_type} (#{i.placement.availability_zone || 'none'}) Tags: Name: #{i.tags.find { |tag| tag.key == 'Name' }&.value || 'unnamed'}")
        instances[i.instance_type.to_s] += 1
      end
    end

    unused_reservations = reservations.clone
    unreserved_instances = instances.clone

    instances.each do |type, count|
      unused_reservations[type] -= count
      unused_reservations[type] = 0 if unused_reservations[type].negative?
    end

    reservations.each do |type, count|
      unreserved_instances[type] -= count
      unreserved_instances[type] = 0 if unreserved_instances[type].negative?
    end

    unless unused_reservations.empty?
      puts 'Unused Reservations:'
      puts Hirb::Helpers::Table.render(unused_reservations.map do |type, count|
        { type: type, unused_count: count }
      end)
    end
    return if unreserved_instances.empty?

    puts 'Unreserved Instances:'
    puts Hirb::Helpers::Table.render(unreserved_instances.map do |type, count|
      { type: type, unreserved_count: count }
    end)
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

  MULTIPART_ETAG = 'MultipartETag'
  # Initializes the AwsStorage instance with the specified bucket name and options.
  #
  # @param bucket_name [String] The name of the S3 bucket.
  # @param options [Hash] Additional options for the AWS S3 client (region,credentials, etc.)
  def initialize(bucket_name, **options)
    @logger = Logger.new(options.delete(:log_file) || $stdout)
    @logger.level = options.delete(:log_level) || Logger::WARN
    puts "Logger level set to #{@logger.level}" if @logger.level != Logger::WARN

    @bucket_name = bucket_name
    @client = Aws::S3::Client.new(**options)
    puts "AwsStorage: Using region: #{Rainbow(@client.config.region).orange}" if @client.config.region
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

  def self.calculate_multipart_threshold(fsize)
    mb = fsize / 1024 / 1024
    return unless mb >= 5

    (mb / 5).clamp(2, 10) * 1024 * 1024
  end

  def self.calculate_file_etag(file_path)
    return 'NoETag' unless File.exist?(file_path)

    # Calculate the ETag for the file
    Digest::MD5.file(file_path).hexdigest
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

    def was_multipart?
      !@multipart_threshold.nil?
    end

    # Uploads a file to an Amazon S3 object by using a managed uploader.
    #
    # @param file_path [String] The path to the file to upload.
    # @return [Boolean] True when the file is uploaded; otherwise false.
    def upload_file(file_path)
      fsize = File.size(file_path)
      @multipart_threshold = AwsStorage.calculate_multipart_threshold(fsize)
      # cursor = TTY::Cursor
      progress_bar = ProgressBar.create(title: File.basename(file_path).rjust(40), total: fsize / 1024, format: "%t #{Rainbow('|%B|').blue} %p%% %e %r KB/s")
      progress_proc = proc do |bytes, _totals|
        progress_bar.progress = bytes.sum / 1024
      end
      @object.upload_file(file_path, progress_callback: progress_proc, multipart_threshold: @multipart_threshold)
      # puts "#{cursor.up}#{cursor.clear_line}Upload complete: #{file_path} -> #{@object.bucket.name}:#{@object.key}"
      # Annoying bug when sometimes the progress bar is duplicated at the end
      true
    rescue Interrupt
      puts "\nUpload interrupted."
      false
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
                          begin
                            res = @bucket.client.get_object_tagging(bucket: @bucket.name, key: obj.key)
                            AwsStorage.calculate_file_etag(obj.key) == res.tag_set.find { |tag| tag.key == AwsStorage::MULTIPART_ETAG }&.value ? 'Match' : 'NoMatch'
                          rescue Aws::Errors::ServiceError => e
                            puts "Couldn't retrieve tags for #{obj.key}. Here's why: #{e.message}"
                            'NoMatch'
                          end
                        else
                          "\"#{AwsStorage.calculate_file_etag(obj.key)}\"" == obj.etag ? 'Match' : 'NoMatch'
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
      objs
    rescue Aws::Errors::ServiceError => e
      puts "Couldn't list objects in bucket #{bucket.name}. Here's why: #{e.message}"
    end
  end

  def download_last_listed(dry_run: false, no_overwrite: true, force: false)
    return if @last_list.nil?

    @last_list.each do |obj|
      download(obj, dry_run: dry_run, no_overwrite: no_overwrite, force: force)
    end
  end

  def download(obj, dry_run: false, no_overwrite: true, force: false)
    full_file_path = File.expand_path(obj[:name])
    if File.exist?(full_file_path) && !force
      if no_overwrite
        puts "Skipping #{obj[:name]}, exists and no_overwrite is set."
        return
      elsif obj[:local_etag] == 'Match'
        puts "Skipping #{obj[:name]}, has the same size and ETag."
        return
      end
    end
    return if dry_run

    object = Aws::S3::Object.new(@bucket_name, obj[:name], client: @client)
    FileUtils.mkdir_p(File.dirname(full_file_path))
    progress_bar = ProgressBar.create(title: File.basename(obj[:name]).rjust(40), total: object.size / 1024, format: "%t #{Rainbow('|%B|').blue} %p%% %e %r KB/s")
    progress_proc = proc { |bytes| progress_bar.progress = bytes.sum / 1024 }
    object.download_file(full_file_path, progress_callback: progress_proc, dry_run: dry_run)
  end

  def upload(file_path, dry_run: false, no_overwrite: true, force: false)
    full_file_path = File.expand_path(file_path)
    object_key = Pathname.new(full_file_path).relative_path_from(Pathname.pwd).to_s
    curr_obj = @bucket.object(object_key)
    if !force && curr_obj.exists?
      if no_overwrite
        puts "Skipping #{file_path}, exists and no_overwrite is set."
        return
      elsif curr_obj.size == File.size(full_file_path)
        local_etag = AwsStorage.calculate_file_etag(full_file_path)
        if curr_obj.etag !~ /.*-\d+/ && curr_obj.etag == "\"#{local_etag}\""
          puts "Skipping #{file_path}, has the same size and ETag."
          return
        elsif curr_obj.size == File.size(full_file_path) && curr_obj.etag =~ /.*-\d+/
          begin
            res = @client.get_object_tagging(bucket: @bucket_name, key: object_key)
            if res.tag_set.any? { |tag| tag.key == AwsStorage::MULTIPART_ETAG && tag.value == local_etag }
              puts "Skipping #{file_path}, has the same size and Multipart ETag."
              return
            end
          rescue Aws::Errors::ServiceError => e
            puts "WARN: Couldn't retrieve tags for #{object_key}. Here's why: #{e.message}"
          end
        end
      end
    end
    return if dry_run

    object = Aws::S3::Object.new(@bucket_name, object_key, client: @client)
    wrapper = ObjectUploadFileWrapper.new(object)
    return unless wrapper.upload_file(full_file_path)
    return unless wrapper.was_multipart?

    params = { bucket: @bucket_name,
               key: object_key,
               tagging: {
                 tag_set: [
                   { key: AwsStorage::MULTIPART_ETAG, value: AwsStorage.calculate_file_etag(full_file_path) }
                 ]
               } }
    @client.put_object_tagging(params)
  end

  def upload_many(glob_pattern, dry_run: true, no_overwrite: true, force: false)
    return unless @bucket

    Dir.glob(glob_pattern).each do |file_path|
      next unless File.file?(file_path)

      upload(file_path, dry_run: dry_run, no_overwrite: no_overwrite, force: force)
    end
  end

  def list(glob_pattern = nil, max_objects = 100, local_etag: false)
    return unless @bucket

    wrapper = BucketListObjectsWrapper.new(@bucket)
    @last_list = wrapper.list_objects(glob_pattern, max_objects, local_etag: local_etag)
  end

  def delete(name, dry_run: true)
    @client.delete_object(bucket: @bucket_name, key: name, dry_run: dry_run)
  end

  def delete_many(glob_pattern, dry_run: true)
    return unless @bucket

    objs = @bucket.objects.select { |obj| glob_pattern.nil? || File.fnmatch(glob_pattern, obj.key, File::FNM_EXTGLOB) }
    objs.each do |obj|
      print "Are you sure you want to delete #{obj.key}? ([yY] yes/[n] no/[N] no to all) "
      confirmation = $stdin.gets.chomp
      if confirmation.downcase == 'y'
        if dry_run
          puts "#{obj.key} would be deleted but DryRun is set."
        else
          @client.delete_object(bucket: @bucket_name, key: obj.key)
          puts "#{obj.key} has been deleted."
        end
      elsif confirmation == 'n'
        puts "#{obj.key} was not deleted."
      elsif confirmation == 'N'
        puts 'No more files will be deleted.'
        break
      end
    end
  end
end

def run_with_args(args)
  options = {
    overwrite: false,
    tags: {},
    list_add_tags: {}
  }
  command = args[0]
  command_list = %w[s3 ec2 cost]
  valid_command = command_list.include?(command)
  parser = OptionParser.new do |opts| # rubocop:disable Metrics/BlockLength
    opts.banner = 'Usage: aws_tasks.rb [command] [options]'
    unless valid_command
      opts.separator "Commands: #{command_list.join(' | ')}"
      opts.separator 'For command help run aws_tasks.rb [command] -h'
    end

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
      opts.on('--local-etag', 'Check local ETag for files in the bucket') do
        options[:local_etag] = true
      end
      opts.on('-o', '--overwrite', 'Overwrite existing files if they differ') do
        options[:overwrite] = true
      end
      opts.on('--force', 'Force overwrite of existing files') do
        options[:force] = true
      end
      opts.on('-d', '--download', 'Download listed files') do
        raise OptionParser::InvalidArgument, 'Download option requires -l/--list' unless options[:list]

        options[:download] = true
        options[:local_etag] = true # always check local ETag when downloading
      end

      opts.on('--delete-many GLOB', 'Delete files from the bucket matching the glob pattern') do |glob|
        options[:delete] = glob
      end
    when 'ec2'
      opts.on('-n', '--names expr1,expr2,expr3', Array, 'Specify EC2 `Name` tags for filtering lists. expr will be used as regular expressions for matching') do |names|
        options[:tags].merge!({ Name: names.map(&:strip) })
      end
      opts.on('-t', '--tag KEY=VALUE', 'Specify tags for filtering') do |tag|
        options[:tags].merge!(Hash[*tag.split('=').map(&:strip)])
      end
      opts.on('--list-add-tag KEY=VALUE', 'Add tags to the last list resources filtered by --names or --tag') do |tag|
        options[:list_add_tags].merge!(Hash[*tag.split('=').map(&:strip)])
      end
      opts.on('--add-tags RESOURCE_ID', 'Add tags specified with --tag or --names to resource RESOURCE_ID. For names only the first name will be used.') do |resource_id|
        options[:add_tags] = resource_id
      end
      opts.on('--volumes', 'List EC2 volumes') do
        options[:volumes] = true
      end
      opts.on('--volume-type VOLUME_TYPE', "Specify the volume type: #{VALID_VOLUME_TYPES.join(', ')}") do |volume_type|
        raise OptionParser::InvalidArgument, "Invalid volume type: #{volume_type}. Valid options are: #{VALID_VOLUME_TYPES.join(', ')}" unless VALID_VOLUME_TYPES.include?(volume_type)

        options[:volume_type] = volume_type
      end
      opts.on('--iops IOPS', Integer, 'Specify the IOPS for the volume') do |iops|
        options[:iops] = iops
      end
      opts.on('--start', 'Start EC2 instances') do
        options[:start] = true
      end
      opts.on('--stop', 'Stop EC2 instances') do
        options[:stop] = true
      end
      opts.on('--reservations', 'List EC2 reservations and unreserved instances') do
        options[:reservations] = true
      end

    when 'help', '-h', '--help'
      puts opts
      exit
    end

    if valid_command
      opts.on('--debug', 'Enable debug logging') do
        options[:log_level] = Logger::DEBUG
      end
      opts.on('--info', 'Enable info logging') do
        options[:log_level] = Logger::INFO
      end
      opts.on('--log-file FILE', 'Log output to a file instead of stdout') do |log_file|
        options[:log_file] = log_file
      end
      opts.on('--region REGION', 'AWS region to use (default is env var AWS_REGION or ~/.aws/config settings)') do |region|
        options[:region] = region
      end
      opts.on('--config CONFIG_FILE', 'Specify to load config.yml for multiple region support') do |config_file|
        if command != 's3'
          options[:config_file] = config_file
        else
          puts "#{Rainbow('WARNING').yellow} Config file option is not supported for S3 command."
        end
      end
      if command != 'cost'
        opts.on('--dry-run', 'Perform a dry run (no changes will be made)') do
          options[:dry_run] = true
        end
      end
    end
    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit
    end
  end
  begin
    parser.parse!(args[1..])
  rescue StandardError => e
    puts e.message
    exit 1
  end

  return unless valid_command

  config = if options[:config_file]
             YAML.load_file(options[:config_file])
           else
             { 'regions' => [options[:region]] }
           end

  case command
  when 's3'
    if options[:bucket].nil?
      puts 'Bucket name is required for S3 operations.'
      return
    end
    s = if options[:region]
          AwsStorage.new(options[:bucket], region: options[:region], log_level: options[:log_level], log_file: options[:log_file])
        else
          AwsStorage.new(options[:bucket], log_level: options[:log_level], log_file: options[:log_file])
        end
    # Now you can use the options hash to determine what to do
    if options[:list]
      s.list(options[:glob], local_etag: options[:local_etag])
      s.download_last_listed(dry_run: options[:dry_run], no_overwrite: !options[:overwrite], force: options[:force]) if options[:download]
    elsif options[:upload]
      s.upload(options[:upload], dry_run: options[:dry_run], no_overwrite: !options[:overwrite], force: options[:force])
    elsif options[:upload_many]
      s.upload_many(options[:upload_many], dry_run: options[:dry_run], no_overwrite: !options[:overwrite], force: options[:force])
    elsif options[:delete]
      s.delete_many(options[:delete], dry_run: options[:dry_run])
    end
  when 'ec2'
    config['regions'].each do |region|
      aws = if region
              AwsTasks.new(region: region, log_level: options[:log_level], log_file: options[:log_file])
            else
              AwsTasks.new(log_level: options[:log_level], log_file: options[:log_file])
            end
      if options[:add_tags]
        aws.add_tags(options[:add_tags], options[:tags], dry_run: options[:dry_run])
      elsif options[:volumes]
        aws.list_volumes(options[:tags])
        if !options[:tags].empty? && (options[:volume_type] || options[:iops])
          aws.modify_volumes(
            volume_type: options[:volume_type],
            iops: options[:iops],
            dry_run: options[:dry_run]
          )
        end
        aws.list_add_tags(options[:list_add_tags], dry_run: options[:dry_run]) unless options[:list_add_tags].empty?
      elsif options[:reservations]
        aws.list_reservations
      else
        aws.list_instances(options[:tags])
        aws.start_instances(dry_run: options[:dry_run]) if options[:start] && !options[:tags].empty?
        aws.stop_instances(dry_run: options[:dry_run]) if options[:stop] && !options[:tags].empty?
        aws.list_add_tags(options[:list_add_tags], dry_run: options[:dry_run]) unless options[:list_add_tags].empty?
      end
    end
  when 'cost'
    config['regions'].each do |region|
      aws = if region
              AwsTasks.new(region: region, log_level: options[:log_level], log_file: options[:log_file])
            else
              AwsTasks.new(log_level: options[:log_level], log_file: options[:log_file])
            end
      aws.cost_report
    end
  end
end

if $PROGRAM_NAME == __FILE__
  # if run with pry: `ruby -rpry aws_tasks.rb`
  if defined?(Pry) && ARGV.count.zero?
    binding.pry # rubocop:disable Lint/Debugger
  else
    run_with_args(ARGV)
  end
end
