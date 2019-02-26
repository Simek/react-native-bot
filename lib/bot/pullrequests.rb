require 'octokit'
require 'active_support/all'

module Bot
  class PullRequests

    def initialize(repo)
      @repo = repo
      @label_no_test_plan = "PR: Missing Test Plan"
      @label_has_test_plan = "PR: Includes Test Plan"
      @label_no_changelog = "PR: Missing Changelog"
      @label_has_changelog = "PR: Includes Changelog"
      @label_cla_true = "CLA Signed"
      @label_cla_false = "PR: No CLA"
      @label_pr_merged = "PR: Merged"
      @label_import_started = "Import Started"
      @label_import_failed = "Import Failed"
      @label_pr_blocked_on_fb = "PR: Blocked on FB"
      @label_pr_needs_review = "PR: Internal Diff Needs Review"
      @label_pr_needs_love = "PR: Internal Diff Needs FB Love"
      
      @changelogRegex = /\[\s?(?<category>General|iOS|Android|.*)\s?\]\s*?\[\s?(?<type>Added|Changed|Deprecated|Removed|Fixed|Security)\s?\]\s?\-\s?(?<message>.*)/
    end

    def perform
      candidates.each do |candidate|
        prs = Octokit.search_issues(candidate[:search], { :per_page => 100 })
        prs.items.each do |pr|
          process(pr, candidate)
        end
      end
    end

    def candidates
      [
        {
          :search => "repo:#{@repo} is:pr is:open -label:\"#{@label_cla_true}\" -label:\"#{@label_cla_false}\" created:<=#{1.days.ago.to_date.to_s}",
          :action => 'add_cla_false'
        },
        {
          :search => "repo:#{@repo} is:pr is:open label:\"#{@label_cla_false}\" label:\"#{@label_cla_true}\"",
          :action => 'remove_cla_false'
        },
        {
          :search => "repo:#{@repo} is:pr is:open created:>=#{2.days.ago.to_date.to_s}",
          :action => 'lint_pr'
        },
        {
          :search => "repo:#{@repo} is:pr is:open updated:>=#{2.days.ago.to_date.to_s} label:\"#{@label_no_test_plan}\"",
          :action => 'lint_pr'
        },
        {
          :search => "repo:#{@repo} is:pr is:open updated:>=#{2.days.ago.to_date.to_s} label:\"#{@label_no_changelog}\"",
          :action => 'lint_pr'
        },
        {
          :search => "repo:#{@repo} is:open is:pr -label:\"#{@label_has_changelog}\" -label:\"#{@label_no_changelog}\"",
          :action => 'check_changelog'
        },
        {
          :search => "repo:#{@repo} is:open is:pr label:\"#{@label_no_changelog}\"",
          :action => 'check_changelog'
        },
        {
          :search => "repo:#{@repo} is:closed is:pr label:\"#{@label_pr_merged}\"",
          :action => 'remove_import_labels'
        },
      ]
    end

    def strip_comments(text)
      return "" unless text
      regex = /(?=<!--)([\s\S]*?-->)/m
      text.gsub(regex, "")
    end

    def process(pr, candidate)
      if candidate[:action] == 'check_changelog'
        check_changelog(pr)
      end
      if candidate[:action] == 'lint_pr'
        lint_pr(pr)
      end
      if candidate[:action] == 'add_cla_false'
        add_cla_false(pr)
      end
      if candidate[:action] == 'remove_cla_false'
        remove_cla_false(pr)
      end
    end

    def add_cla_false(pr)
      add_labels(pr, [@label_cla_false])
    end

    def remove_cla_false(pr)
      remove_label(pr, @label_cla_false)
    end

    def remove_import_labels(pr)
      remove_labels = [ @label_import_failed, @label_import_started, @label_pr_blocked_on_fb, @label_pr_needs_love, @label_pr_needs_review]
      remove_labels.each do |label|
        remove_label(pr, label)
      end
    end

    def check_changelog(pr)
      body = strip_comments(pr.body)
      changelogCaptureGroups = @changelogRegex.match(body)
      labels = []
      if changelogCaptureGroups
        labels.push @label_has_changelog

        category = changelogCaptureGroups["category"].upcase
        type = changelogCaptureGroups["type"].upcase

        case category
          when "ANDROID"
            label = "Platform: Android"
            labels.push label
          when  "IOS"
            label = "Platform: iOS"
            labels.push label
          when  "TVOS"
            label = "Platform: tvOS"
            labels.push label
          when  "WINDOWS"
            label = "Platform: Windows"
            labels.push label
          when  "MACOS"
            label = "Platform: macOS"
            labels.push label
          when  "LINUX"
            label = "Platform: Linux"
            labels.push label
        end

        case type
          when "ADDED"
            label = "Type: Enhancement"
            labels.push label
          when "FIXED"
            label = "Type: Bug Fix🐛"
            labels.push label
          when "DEPRECATED"
            label = "Type: Deprecation"
            labels.push label
          when "REMOVED"
            label = "Type: Removal"
            labels.push label
          when "SECURITY"
            label = "Type: Security"
            labels.push label
          when "BREAKING"
            label = "Type: Breaking Change💥"
            labels.push label
        end

        remove_label(pr, @label_no_changelog)
      end

      if labels.count > 0
        add_labels(pr, labels)
      end
    end

    def lint_pr(pr)
      labels = []
      comments = Octokit.issue_comments(@repo, pr.number)

      body = strip_comments(pr.body)
      has_test_plan = body.downcase =~ /test plan/

      if ! has_test_plan
        remove_label(pr, @label_has_test_plan)
      end

      changelogCaptureGroups = @changelogRegex.match(body)
      if changelogCaptureGroups
        labels.push @label_has_changelog
        remove_label(pr, @label_no_changelog)
      end

      add_labels(pr, labels)
    end

    def add_labels(issue, labels)
      new_labels = []

      labels.each do |label|
        new_labels.push label unless issue_contains_label(issue, label)
      end

      if new_labels.count > 0
        puts "#{@repo}: [LABELS] 📍 #{issue.html_url}: #{issue.title} --> Adding #{new_labels}"
        Octokit.add_labels_to_an_issue(@repo, issue.number, new_labels)
      end
    end

    def remove_label(issue, label)
      if issue_contains_label(issue,label)
        puts "#{@repo}: [LABELS] ✂️ #{issue.html_url}: #{issue.title} --> Removing #{label}"
        Octokit.remove_label(@repo, issue.number, label)
      end
    end


    def issue_contains_label(issue, label)
      existing_labels = []

      issue.labels.each do |issue_label|
        existing_labels.push issue_label.name if issue_label.name
      end

      existing_labels.include? label
    end

  end
end
