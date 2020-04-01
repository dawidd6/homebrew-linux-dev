require "cli/parser"
require "utils/github"

module Homebrew
  module_function

  def fetch_failed_logs_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `fetch-failed-logs` [<options>] <formula>

        Fetch failed job logs from GitHub Actions workflow run.
      EOS
      switch "--dispatched",
        description: "Search through workflows triggered by repository_dispatch event."
    end
  end

  def print_failed_logs(file)
    # Border lines indexes
    brew_index = -1
    failed_index = -1

    # Find indexes of border lines
    content = File.read(file).lines
    content.each_with_index do |line, index|
      if /.*==> .*FAILED.*/.match?(line)
        failed_index = index
        break
      elsif /.*==>.* .*brew .+/.match?(line)
        brew_index = index
      end
    end

    # One of the border lines weren't found
    return if brew_index.negative? || failed_index.negative?

    # Remove timestamp prefix on every line
    content.map! do |line|
      line.split(" ")[1..-1]&.join(" ")
    end

    # Print only interesting lines
    puts content[brew_index..failed_index]
  end

  def fetch_failed_logs
    fetch_failed_logs_args.parse

    raise FormulaUnspecifiedError if Homebrew.args.named.empty?

    formula = Homebrew.args.resolved_formulae.first
    workflow = args.dispatched? ? "dispatch-build-bottle.yml" : "build-bottles.yml"
    repo = "Homebrew/linuxbrew-core"

    # First get latest workflow runs
    url = "https://api.github.com/repos/#{repo}/actions/workflows/#{workflow}/runs?status=failure"
    response = GitHub.open_api(url, request_method: :GET, scopes: ["repo"])
    workflow_runs = response["workflow_runs"]

    # Then iterate over them and find the matching one...
    workflow_run = workflow_runs.find do |run|
      # If the workflow run was triggered by a repository dispatch event, then
      # check if any step name in all its jobs is equal to formula
      if run["event"] == "repository_dispatch"
        url = run["jobs_url"]
        response = GitHub.open_api(url, request_method: :GET, scopes: ["repo"])
        jobs = response["jobs"]
        jobs.find do |job|
          steps = job["steps"]
          steps.find do |step|
            step["name"].match(formula.name)
          end
        end
      # If the workflow run was triggered by a pull request event, then
      # fetch the head commit, determine which file changed and
      # check if equal to formula
      elsif run["event"] == "pull_request"
        url = "https://api.github.com/repos/#{repo}/commits/#{run["head_sha"]}"
        response = GitHub.open_api(url, request_method: :GET, scopes: ["repo"])
        commit_files = response["files"].map { |f| f["filename"] }
        commit_files.find do |file|
          file[%r{Formula/(.+)\.rb}, 1] == formula
        end
        # Not supported event
      end
    end

    unless workflow_run
      opoo "No workflow run matching the criteria was found"
      return
    end

    oh1 "Workflow run id: #{workflow_run["id"]}"

    # Download logs zipball,
    # create a temporary directory,
    # extract it there and print
    url = workflow_run["logs_url"]
    response = GitHub.open_api(url, request_method: :GET, scopes: ["repo"], parse_json: false)
    Dir.mktmpdir do |tmpdir|
      file = "#{tmpdir}/logs.zip"
      File.write(file, response)
      safe_system("unzip", "-qq", "-d", tmpdir, file)
      Dir["#{tmpdir}/*.txt"].each do |f|
        print_failed_logs f
      end
    end
  end
end
