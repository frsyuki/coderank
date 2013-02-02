require 'grit'
require 'fileutils'

class ShellUtil
  def self.sh(*cmd)
    puts "#{cmd.join(' ')}"
    unless system(*cmd)
      raise "'#{cmd.first}' failed"
    end
  end

  def self.sh_dir(dir, *cmd)
    puts "#{cmd.join(' ')}"
    pid = fork do
      Dir.chdir dir
      exec(*cmd)
      exit! 127
    end
    pid, stat = Process.waitpid2(pid)
    unless stat.success?
      raise "'#{cmd.first}' failed"
    end
  end
end

class Repo
  require 'cgi'

  def initialize(git, cache_dir, url, branch)
    @git = git
    @url = url
    @branch = branch
    @cache_path = File.join cache_dir, Repo.build_cache_dirname(url, branch)
  end

  attr_reader :url, :branch, :cache_path

  def clone_if_not_exists!
    return if Dir.exists?(@cache_path)
    FileUtils.mkdir_p File.dirname(@cache_path)
    puts "> clone #{@url} #{@branch} at #{@cache_path}"
    ShellUtil.sh @git, 'clone', @url, '-b', @branch, '--single-branch', @cache_path
    self
  end

  def update!
    clone_if_not_exists!
    puts "> pull #{@url} #{@branch} at #{@cache_path}"
    ShellUtil.sh_dir @cache_path, @git, 'pull'
  end

  require 'time'

  def aggregate!(since, aggr)
    update!
    grepo = Grit::Repo.new(@cache_path)

    # commits_since doesn't work as I expected...
    #grepo.commits_since(@branch, since).each(&aggr.method(:add))
    since_time = Time.parse(since)
    Grit::Commit.find_all(grepo, @branch, {}).each {|c|
      if c.committed_date >= since_time
        aggr.add(c)
      end
    }

    self
  end

  def self.build_cache_dirname(url, branch)
    name = File.basename(url, '.git')
    [name, branch, url].map {|raw| CGI.escape(raw) }.join('.')
  end
end

class Aggregator
  def initialize(commit_limit=nil, uniq_db=nil)
    @commit_limit = commit_limit || 0x7fffffff
    @uniq_db = uniq_db
    @plus_hash = Hash.new(0)
    @minus_hash = Hash.new(0)
    @name_hash = Hash.new('')
  end

  attr_reader :plus_hash
  attr_reader :minus_hash
  attr_reader :name_hash

  def authors
    @plus_hash.keys
  end

  def add(gcommit)
    if @uniq_db
      id = gcommit.id
      return if @uniq_db[id]
      @uniq_db[id] = ''
    end

    author = gcommit.author.email.to_s
    name = gcommit.author.to_s

    plus = 0
    minus = 0
    gcommit.show.each {|g|
      diff = g.diff
      if diff
        plus += diff.scan(/^\+/).size
        minus += diff.scan(/^\-/).size
      end
    }

    if plus < @commit_limit
      @plus_hash[author] += plus
      @minus_hash[author] += minus
    end

    last_name = @name_hash[author]
    if last_name.length < name.length
      @name_hash[author] = name
    end
  end

  def data
    aggr = Aggregator.new
    aggr.plus_hash.merge!(@plus_hash)
    aggr.minus_hash.merge!(@minus_hash)
    aggr.name_hash.merge!(@name_hash)
    aggr
  end

  def merge!(other)
    other_plus_hash = other.plus_hash
    other_minus_hash = other.minus_hash
    other_name_hash = other.name_hash

    other.authors.each {|a|
      @plus_hash[a] += other_plus_hash[a]
      @minus_hash[a] += other_minus_hash[a]
      last_name = @name_hash[a]
      next_name = other_name_hash[a]
      if last_name.length < next_name.length
        @name_hash[a] = next_name
      end
    }

    self
  end
end

class CodeStat
  def self.run!(url_branches, opts)
    repos = url_branches.map {|url,branch|
      Repo.new(opts[:git], opts[:cache_dir], url, branch)
    }

    para = opts[:parallel] || 3
    commit_limit = opts[:commit_limit] || 10000

    unique = !!opts[:unique]
    if unique
      require 'tokyocabinet'
      uniq_db = TokyoCabinet::ADB.new
      uniq_db.open('*')
      parallel_opts = {:in_threads => para}
    else
      parallel_opts = {:in_processes => para}
    end

    m = Proc.new do |repo|
      aggr = Aggregator.new(commit_limit, uniq_db)
      begin
        repo.aggregate!(opts[:since], aggr)
      rescue
        puts "  ignoring #{repo.url} #{repo.branch}: #{$!}"
        $!.backtrace.each {|bt|
          puts "      #{bt}"
        }
      end
      aggr.data
    end

    if para == 1
      aggrs = repos.map(&m)
    else
      require 'parallel'
      Parallel.map(repos, parallel_opts, &m)
    end

    aggrs.inject(Aggregator.new, &:merge!)
  end
end


if $0 == __FILE__
  require 'optparse'

  opts = {
    :git => 'git',
    :cache_dir =>'/tmp/codestat',
    :since => '1970-01-01',
    :commit_limit => 10000,
  }

  op = OptionParser.new
  op.banner += " <url[ branch]...>"

  op.on('--git BIN', 'git command') {|s|
    opts[:git] = s
  }
  op.on('-c', '--cache-dir DIR', 'cache directory') {|s|
    opts[:cache_dir] = s
  }
  op.on('-s', '--since DATE', 'since') {|s|
    opts[:since] = s
  }
  op.on('-U', '--unique', 'unique commit ids') {
    opts[:unique] = true
  }
  op.on('-l', '--limit LIMIT', 'commit limit', Integer) {|i|
    opts[:commit_limit] = i
  }

  (class<<self;self;end).module_eval do
    define_method(:usage) do |msg|
      puts op.to_s
      puts "error: #{msg}" if msg
      exit 1
    end
  end

  begin
    op.parse!(ARGV)

    if ARGV.empty?
      usage nil
    end

    url_branches = ARGV.map {|a|
      url, branch = a.split(' ',2)
      branch ||= 'master'
      [url, branch]
    }
  rescue
    usage $!.to_s
  end

  aggr = CodeStat.run!(url_branches, opts)

  aggr.authors.each {|a|
    STDERR.puts "#{a},#{aggr.name_hash[a]},#{aggr.plus_hash[a]},#{aggr.minus_hash[a]}"
  }
end

