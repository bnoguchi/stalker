require 'rubygems'
require 'beanstalk-client'
require 'json'
require 'uri'
require 'uuidtools'
require 'pp'

module Stalker
	extend self

  # Defaults the eigenclass's @does_autogen_job_id to true.
  # Putting it in a singleton_method_added hook avoids
  # alternative implementations' multiple calls to
  #     @does_autogen_job_id = true if @does_autogen_job_id.nil?
  # Instead, the default is set once when the #does_autogen_job_id
  # is first defined under the eigenclass (i.e., under (class << self)).
  def self.singleton_method_added(name)
    @does_autogen_job_id = true if name.to_sym == :does_autogen_job_id
  end

  class << self; attr_accessor :does_autogen_job_id; end

	def enqueue(job, args={})
		beanstalk.use job
    pp self.does_autogen_job_id
    args[:job_id] = UUIDTools::UUID.random_create.to_s if self.does_autogen_job_id
		beanstalk.put [ job, args ].to_json
    return args[:job_id]
	rescue Beanstalk::NotConnected => e
		failed_connection(e)
	end

	def job(j, &block)
		@@handlers ||= {}
		@@handlers[j] = block
	end

	class NoJobsDefined < RuntimeError; end
	class NoSuchJob < RuntimeError; end

	def prep(jobs=nil)
		raise NoJobsDefined unless defined?(@@handlers)

		jobs ||= all_jobs

		jobs.each do |job|
			raise(NoSuchJob, job) unless @@handlers[job]
		end

		log "Working #{jobs.size} jobs: [ #{jobs.join(' ')} ]"

		jobs.each { |job| beanstalk.watch(job) }

		beanstalk.list_tubes_watched.each do |server, tubes|
			tubes.each { |tube| beanstalk.ignore(tube) unless jobs.include?(tube) }
		end
	rescue Beanstalk::NotConnected => e
		failed_connection(e)
	end

	def work(jobs=nil)
		prep(jobs)
		loop { work_one_job }
	end

	def work_one_job
		job = beanstalk.reserve
		name, args = JSON.parse job.body
		log_job_begin(name, args)
		handler = @@handlers[name]
		raise(NoSuchJob, name) unless handler
		handler.call(args)
		job.delete
		log_job_end(name)
	rescue Beanstalk::NotConnected => e
		failed_connection(e)
	rescue SystemExit
		raise
	rescue => e
		STDERR.puts exception_message(e)
		job.bury rescue nil
		log_job_end(name, 'failed')
	end

	def failed_connection(e)
		STDERR.puts exception_message(e)
		STDERR.puts "*** Failed connection to #{beanstalk_url}"
		STDERR.puts "*** Check that beanstalkd is running (or set a different BEANSTALK_URL)"
		exit 1
	end

	def log_job_begin(name, args)
		args_flat = unless args.empty?
			'(' + args.inject([]) do |accum, (key,value)|
				accum << "#{key}=#{value}"
			end.join(' ') + ')'
		else
			''
		end

		log [ "->", name, args_flat ].join(' ')
		@job_begun = Time.now
	end

	def log_job_end(name, type="finished")
		ellapsed = Time.now - @job_begun
		ms = (ellapsed.to_f * 1000).to_i
		log "-> #{name} #{type} in #{ms}ms"
	end

	def log(msg)
		puts "[#{Time.now}] #{msg}"
	end

	def beanstalk
		@@beanstalk ||= Beanstalk::Pool.new([ beanstalk_host_and_port ])
	end

	def beanstalk_url
		ENV['BEANSTALK_URL'] || 'beanstalk://localhost/'
	end

	class BadURL < RuntimeError; end

	def beanstalk_host_and_port
		uri = URI.parse(beanstalk_url)
		raise(BadURL, beanstalk_url) if uri.scheme != 'beanstalk'
		return "#{uri.host}:#{uri.port || 11300}"
	end

	def exception_message(e)
		msg = [ "Exception #{e.class} -> #{e.message}" ]

		base = File.expand_path(Dir.pwd) + '/'
		e.backtrace.each do |t|
			msg << "   #{File.expand_path(t).gsub(/#{base}/, '')}"
		end

		msg.join("\n")
	end

	def all_jobs
		@@handlers.keys
	end

	def clear!
		@@handlers = nil
	end
end
