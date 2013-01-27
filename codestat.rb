require 'grit'
require 'fileutils'
require 'parallel'

class ShellUtil
  def self.sh(*cmd)
    puts "#{cmd.join(' ')}"
    unless system(*cmd)
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
    Dir.chdir(@cache_path) do
      ShellUtil.sh @git, 'pull'
    end
  end

  def aggregate!(since, aggr)
    update!
    grepo = Grit::Repo.new(@cache_path)
    grepo.commits_since(@branch, since).each(&aggr.method(:add))
    self
  end

  def self.build_cache_dirname(url, branch)
    name = File.basename(url, '.git')
    [name, branch, url].map {|raw| CGI.escape(raw) }.join('.')
  end
end

class Aggregator
  def initialize
    @plus_hash = Hash.new(0)
    @minus_hash = Hash.new(0)
  end

  attr_reader :plus_hash
  attr_reader :minus_hash

  def authors
    @plus_hash.keys
  end

  def add(gcommit)
    author = gcommit.author.to_s
    plus = 0
    minus = 0
    gcommit.show.each {|g|
      diff = g.diff
      if diff
        plus += diff.scan(/^\+/).size
        minus += diff.scan(/^\-/).size
      end
    }
    @plus_hash[author] += plus
    @minus_hash[author] += minus
  end

  def merge!(other)
    other_plus_hash = other.plus_hash
    other_minus_hash = other.minus_hash

    other.authors.each {|a|
      @plus_hash[a] += other_plus_hash[a]
      @minus_hash[a] += other_minus_hash[a]
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

    aggrs = Parallel.map(repos, :in_processes=>para) {|repo|
      aggr = Aggregator.new
      begin
        repo.aggregate!(opts[:since], aggr)
      rescue
        puts "  ignoring #{repo.url} #{repo.branch}: #{$!}"
        $!.backtrace.each {|bt|
          puts "      #{bt}"
        }
      end
      aggr
    }

    aggrs.inject(Aggregator.new, &:merge!)
  end
end


if $0 == __FILE__
  require 'optparse'

  opts = {
    :git => 'git',
    :cache_dir =>'/tmp/codestat',
    :since => '1970-01-01',
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
    STDERR.puts "#{a},#{aggr.plus_hash[a]},#{aggr.minus_hash[a]}"
  }
end

