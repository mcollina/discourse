module Demon; end

# intelligent fork based demonizer for sidekiq
class Demon::Base

  def self.start(count)
    @demons ||= {}
    count.times do |i|
      (@demons["#{prefix}_#{i}"] ||= new(i)).start
    end
  end

  def self.stop
    @demons.values.each do |demon|
      demon.stop
    end
  end

  def initialize(index)
    @index = index
    @pid = nil
    @parent_pid = Process.pid
    @monitor = nil
  end

  def pid_file
    "#{Rails.root}/tmp/pids/#{self.class.prefix}_#{@index}.pid"
  end

  def stop
    if @monitor
      @monitor.kill
      @monitor.join
      @monitor = nil
    end

    if @pid
      Process.kill("SIGHUP",@pid)
      @pid = nil
    end
  end

  def start
    if existing = already_running?
      # should not happen ... so kill violently
      Process.kill("SIGTERM",existing)
    end

    return if @pid

    if @pid = fork
      write_pid_file
      monitor_child
      return
    end

    monitor_parent
    establish_app
    after_fork
  end

  def already_running?
    if File.exists? pid_file
      pid = File.read(pid_file).to_i
      if alive?(pid)
        return pid
      end
    end

    nil
  end

  private

  def monitor_child
    @monitor ||= Thread.new do
      while true
        sleep 5
        unless alive?(@pid)
          STDERR.puts "#{@pid} died, restarting sidekiq"
          @pid = nil
          start
        end
      end
    end
  end

  def write_pid_file
    FileUtils.mkdir_p(Rails.root + "tmp/pids")
    File.open(pid_file,'w') do |f|
      f.write(@pid)
    end
  end

  def delete_pid_file
    File.delete(pid_file)
  end

  def monitor_parent
    Thread.new do
      while true
        exit unless alive?(@parent_pid)
        sleep 1
      end
    end
  end

  def alive?(pid)
    begin
      Process.getpgid(pid)
      true
    rescue Errno::ESRCH
      false
    end
  end

  def establish_app


    ActiveRecord::Base.connection_handler.clear_active_connections!
    ActiveRecord::Base.establish_connection
    $redis.client.reconnect
    Rails.cache.reconnect
    MessageBus.after_fork

    Signal.trap("HUP") do
      begin
        delete_pid_file
      ensure
        exit
      end
    end

    # keep stuff simple for now
    $stdout.reopen("/dev/null", "w")
    # $stderr.reopen("/dev/null", "w")
  end

  def after_fork
  end
end

class Demon::Sidekiq < Demon::Base
  def self.prefix
    "sidekiq"
  end

  private

  def after_fork
    require 'sidekiq/cli'

    begin
      cli = Sidekiq::CLI.instance
      cli.parse([])
      cli.run
    rescue => e
      STDERR.puts e.message
      STDERR.puts e.backtrace.join("\n")
      exit 1
    end

  end
end