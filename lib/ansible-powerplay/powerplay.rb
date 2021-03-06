# -*- coding: utf-8 -*-
require 'ansible-powerplay'

CRITICAL = Mutex.new

module Powerplay
  module Play
    def self.clopts
      @clopts ||= Thor::CoreExt::HashWithIndifferentAccess.new DSL::_global[:options]
    end

    module Tmux

      def self.current_tty
        %x[tty].chop
      end

      # Get a list of the ptys
      # Note that this code is a bit innefficient, but will only be
      # executed once in the loop.
      def self.pane_ttys
        @window = if Play::clopts.nil? or Play::clopts[:tmux] == 0
                    ''
                  else
                    " -t #{Play::clopts[:tmux]} "
                  end
        @ptys ||= if Play::clopts.nil? or Play::clopts[:tmux]
                    %x[tmux list-panes #{@window} -F '\#{pane_tty},']
                      .inspect
                      .chop
                      .split(",")
                      .map{ |s| s.strip.sub(/\\n|\"/, '') }
                      .reject{ |pty| pty == %x(tty).chop }
                      .reject{ |pty| pty == '' }
                  else
                    [current_tty]
                  end
      end
      
      # thread-safe way to grab a new tty
      def self.grab_a_tty
        tty = nil
        CRITICAL.synchronize {
          @@tty_count ||= -1
          @@tty_count = (@@tty_count+1) % pane_ttys.size
          tty = pane_ttys[@@tty_count] 
        }
        tty
      end
    end

    module Ansible
      PLAYBOOK = "ansible-playbook"
      OPTS = ""

      def self.playbooks
        plays = Play::clopts[:play].map{ |y| y.to_sym }
        DSL::_global[:playbooks].each do |pplay, group|
          yield pplay, group if plays.first == :all or plays.member? pplay
        end
      end
      
      # groups are serial
      def self.groups(playbook)
        grps = Play::clopts[:group].map{ |g| g.to_sym}
        playbook.groups.each do |group|
          yield group if grps.first == :all or grps.member?(group.type)  
        end
      end

      def self.run_book(book, bucher, book_threads, errors)
        dryrun = Play::clopts[:dryrun]
        extra = Play::clopts[:extra]
        tags = Play::clopts[:tags]
        sktags = Play::clopts[:sktags]
        tagstr = ''
        if tags and sktags
          puts "Cannot use both --tags (#{tags}) and --skip-tags (#{sktags})"
          exit 5 
        end
        tagstr += %( --tags "#{tags}" ) unless tags.nil?
        tagstr += %( --skip-tags "#{sktags}" ) unless sktags.nil?
        tty ||= Tmux.grab_a_tty
        puts " tty == #{tty} (#{Tmux.pane_ttys.last})" unless DSL::_verbosity < 2
        if bucher.first == :all or bucher.member?(book.type)
          puts "        BOOK #{book.type}"
          inv = if book.config.member? :inventory 
                  "-i #{book.config[:inventory].first}" 
                else
                  ''
                end
          xxv = [extra[book.type], extra[:all]].compact.join(' ')
          apcmd = %|#{PLAYBOOK} #{OPTS} #{inv} #{book.config[:playbook_directory].first}/#{book.yaml} #{tagstr} --extra-vars "#{book.aparams} #{xxv}" >#{tty}|
          unless DSL::_verbosity < 1
            puts "==============================\nRunning command:"
            puts "#{apcmd}".yellow
            puts "------------------------------" 
          end
          book_threads << Thread.new {
            std, status = Open3.capture2e apcmd
            errors << [book.yaml, apcmd, std] unless status.success?
          } unless dryrun
        end
      end

      def self.power_run
        bucher = Play::clopts[:book].map{ |b| b.to_sym }
        congroups = Play::clopts[:congroups]
        playbooks do |pname, playbook|
          group_threads = []
          puts "PLAYBOOK #{pname} (group=#{Play::clopts[:group]}) -->"
          groups playbook do |group|
            tg = nil
            group_threads << (tg = Thread.new {
                                puts "    GROUP #{group.type} (book=#{bucher}, cg=#{congroups}) -->"
                                book_threads = []
                                errors = []
                                group.books.each { |book| run_book(book, bucher, book_threads, errors) }
                                book_threads.each{ |t| t.join }
                                unless errors.empty?
                                  errors.each do |yaml, cmd, txt|
                                    puts '=' * 30
                                    puts ('*' * 10) + ' ' + yaml
                                    puts txt
                                    puts '-' * 30
                                    puts cmd
                                  end
                                  exit 10
                                end
                              })
            # Always wait here unless we're concurrent
            group_threads.join unless congroups
          end
          group_threads.each{ |t| t.join }
        end
      end
    end
  end
end
