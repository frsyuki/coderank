require File.expand_path('codestat', File.dirname(__FILE__))

class RankRepo < Repo
  def initialize(git, cache_dir, url, branch, file)
    super(git, cache_dir, url, branch)
    @file = file
    @path = File.join(cache_path, @file)
  end

  def write!(data)
    update!

    # normalize data
    data = data.force_encoding('UTF-8').encode('UTF-16LE', :invalid=>:replace, :undef=>:replace).encode('UTF-8')

    if File.exists?(@path)
      before = File.read(@path).force_encoding('UTF-8')
    else
      needs_add = true
      FileUtils.mkdir_p File.dirname(@path)
    end

    if before == data
      return
    end

    File.open(@path, "w") {|f| f.write data }

    puts "> push #{@url} #{@branch} at #{@cache_path}"
    Dir.chdir(@cache_path) do
      if needs_add
        ShellUtil.sh @git, 'add', @file
      end
      ShellUtil.sh @git, 'commit', @file, '-m', 'updated by coderank'
      ShellUtil.sh @git, 'push'
    end
  end

  class Formatter
    require 'erb'
    require 'cgi'

    DEFAULT_ERB = <<EOF
% authors.each_with_index {|a,i|
  <%= i %>. <%=e a.name %> +<%= a.plus %> -<%= a.minus %>

% }
EOF

    def initialize(var, erb_path=nil)
      erb_data = erb_path ? File.read(erb_path) : DEFAULT_ERB
      @var = var
      @erb = ERB.new(erb_data, nil, '%<>')
    end

    attr_reader :var

    Author = Struct.new(:name, :plus, :minus)

    def format(aggr)
      authors = aggr.authors.map {|a|
        Author.new(aggr.name_hash[a], aggr.plus_hash[a], aggr.minus_hash[a])
      }
      authors = authors.sort_by {|a| -a.plus }
      @erb.result(binding)
    end

    def e(s)
      CGI.escapeHTML(s.to_s)
    end
  end
end

class ListRepo < Repo
  def initialize(git, cache_dir, url, branch, file)
    super(git, cache_dir, url, branch)
    @file = file
    @path = File.join(cache_path, @file)
  end

  def read_data!
    update!
    if File.exists?(@path)
      File.read(@path)
    else
      ''
    end
  end

  LINE_REGEXP = /^(?!\#)[\s\*\.0-9]*([^\s]+)(?:\s+([^\s]+))?/

  def read!
    url_branches = []
    read_data!.each_line {|line|
      if m = LINE_REGEXP.match(line)
        url = m[1]
        branch = m[2] || 'master'
        url_branches << [url, branch]
      end
    }
    url_branches.uniq
  end
end

require 'optparse'

if $0 == __FILE__
  opts = {
    :git => 'git',
    :cache_dir =>'/tmp/coderank',
    :since => '1970-01-01',
    :parallel => 3,
    :list_repo => nil,
    :list_file => 'list.md',
    :list_branch => 'master',
    :rank_repo => nil,
    :rank_file => 'rank.md',
    :rank_branch => 'master',
    :erb_path => nil,
  }

  op = OptionParser.new
  op.banner += " "

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
  op.on('-P', '--parallel N', 'parallel', Integer) {|i|
    opts[:parallel] = i
  }

  op.on('-u', '--gh-user USER', 'github user') {|s|
    opts[:gh_user] = s
  }
  op.on('-r', '--gh-repo NAME', 'github repository name') {|s|
    opts[:gh_repo] = s
  }
  op.on('--erb PATH', 'erb file to format the ranking page') {|s|
    opts[:erb_path] = s
  }

  op.on('-L', '--list-repo URL', '') {|s|
    opts[:list_repo] = s
  }
  op.on('-F', '--list-file PATH', '') {|s|
    opts[:list_file] = s
  }
  op.on('-B', '--list-branch BRANCH', '') {|s|
    opts[:list_branch] = s
  }
  op.on('-R', '--rank-repo URL', '') {|s|
    opts[:rank_repo] = s
  }
  op.on('-O', '--rank-file PATH', '') {|s|
    opts[:rank_file] = s
  }
  op.on('-C', '--rank-branch BRANCH', '') {|s|
    opts[:rank_branch] = s
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

    unless ARGV.empty?
      usage nil
    end

    if !opts[:list_repo]
      if !opts[:gh_user] || !opts[:gh_repo]
        raise "--list-repo or (--gh-user && --gh-repo) options are required"
      end
      opts[:list_repo] = "https://github.com/#{opts[:gh_user]}/#{opts[:gh_repo]}.wiki.git"
    end

    if !opts[:rank_repo]
      if !opts[:gh_user] || !opts[:gh_repo]
        raise "--rank-repo or (--gh-user && --gh-repo) options are required"
      end
      opts[:rank_repo] = "git@github.com:#{opts[:gh_user]}/#{opts[:gh_repo]}.wiki.git"
    end

  rescue
    usage $!.to_s
  end

  list = ListRepo.new(opts[:git], opts[:cache_dir], opts[:list_repo], opts[:list_branch], opts[:list_file])

  rank = RankRepo.new(opts[:git], opts[:cache_dir], opts[:rank_repo], opts[:rank_branch], opts[:rank_file])

  form = RankRepo::Formatter.new(opts, opts[:erb_path])

  url_branches = list.read!

  puts "> repositories:"
  url_branches.each {|url,branch|
    puts ">  * #{url} #{branch}"
  }

  aggr = CodeStat.run!(url_branches, opts)

  data = form.format(aggr)
  rank.write!(data)
end

