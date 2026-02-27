#!/usr/bin/env ruby
# frozen_string_literal: true

# Translation Log Viewer
# Usage: ruby plugins/babel-reunited/view_translation_logs.rb [options]
# Options:
#   --tail N    Show last N lines (default: 20)
#   --filter EVENT_TYPE    Filter by event type (started, completed, failed, skipped)
#   --post-id ID    Filter by post ID
#   --language LANG    Filter by target language

require 'json'
require 'optparse'

class TranslationLogViewer
  LOG_FILE_PATH = "/home/soloara/works/discourse/log/babel_reunited_translation.log"
  
  def initialize
    @options = {}
    parse_options
  end
  
  def run
    unless File.exist?(LOG_FILE_PATH)
      puts "❌ Log file not found: #{LOG_FILE_PATH}"
      return
    end
    
    lines = File.readlines(LOG_FILE_PATH)
    lines = apply_filters(lines)
    lines = lines.last(@options[:tail] || 20)
    
    puts "📊 Translation Logs (#{lines.length} entries)"
    puts "=" * 60
    
    lines.each do |line|
      begin
        log_entry = JSON.parse(line.strip)
        display_log_entry(log_entry)
      rescue JSON::ParserError
        puts "❌ Invalid JSON: #{line.strip}"
      end
    end
  end
  
  private
  
  def parse_options
    OptionParser.new do |opts|
      opts.banner = "Usage: ruby view_translation_logs.rb [options]"
      
      opts.on("--tail N", Integer, "Show last N lines (default: 20)") do |n|
        @options[:tail] = n
      end
      
      opts.on("--filter EVENT_TYPE", "Filter by event type") do |event|
        @options[:event_filter] = event
      end
      
      opts.on("--post-id ID", Integer, "Filter by post ID") do |id|
        @options[:post_id] = id
      end
      
      opts.on("--language LANG", "Filter by target language") do |lang|
        @options[:language] = lang
      end
      
      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit
      end
    end.parse!
  end
  
  def apply_filters(lines)
    lines.select do |line|
      begin
        log_entry = JSON.parse(line.strip)
        
        # Apply filters
        next false if @options[:event_filter] && !log_entry["event"].include?(@options[:event_filter])
        next false if @options[:post_id] && log_entry["post_id"] != @options[:post_id]
        next false if @options[:language] && log_entry["target_language"] != @options[:language]
        
        true
      rescue JSON::ParserError
        false
      end
    end
  end
  
  def display_log_entry(entry)
    timestamp = entry["timestamp"]
    event = entry["event"]
    post_id = entry["post_id"]
    language = entry["target_language"]
    
    # Color coding based on event type
    case event
    when "translation_started"
      color = "\033[36m" # Cyan
      icon = "🚀"
    when "translation_completed"
      color = "\033[32m" # Green
      icon = "✅"
    when "translation_failed"
      color = "\033[31m" # Red
      icon = "❌"
    when "translation_skipped"
      color = "\033[33m" # Yellow
      icon = "⏭️"
    else
      color = "\033[0m" # Reset
      icon = "📝"
    end
    
    puts "#{color}#{icon} [#{timestamp}] #{event.upcase}\033[0m"
    puts "   Post ID: #{post_id} | Language: #{language}"
    
    case event
    when "translation_started"
      puts "   Content Length: #{entry["content_length"]} chars"
    when "translation_completed"
      puts "   Translation ID: #{entry["translation_id"]}"
      puts "   Processing Time: #{entry["processing_time_ms"]}ms"
      puts "   AI Model: #{entry["ai_model"]}"
      if entry["ai_usage"]
        usage = entry["ai_usage"]
        puts "   Tokens: #{usage["prompt_tokens"]} prompt + #{usage["completion_tokens"]} completion"
      end
    when "translation_failed"
      puts "   Error: #{entry["error_message"]}"
      puts "   Processing Time: #{entry["processing_time_ms"]}ms"
    when "translation_skipped"
      puts "   Reason: #{entry["reason"]}"
    end
    
    puts
  end
end

# Run the viewer
viewer = TranslationLogViewer.new
viewer.run
