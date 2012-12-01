use strict;

my $self = 'weenotify';
my @cmd =	( 'ssh'
		, '-q'
		, '-p'
		, '44444'
		, '-i'
		, '/home/jenic/.ssh/ircnotify'
		, 'dracarys.lan'
		);

weechat::register	( $self
			, 'Jenic Rycr <jenic\@wubwub.me>'
			, '0.1'
			, 'GPL3'
			, 'Simple Notify Hook'
			, ''
			, ''
			);

# Functions
sub notify {
	my ($data, $signal, $sdata) = @_;
	system(@cmd, $sdata);
	return weechat::WEECHAT_RC_OK;
}

# Hooks
weechat::hook_signal('weechat_highlight', 'notify', '');
#weechat.hook_signal('irc_pv', 'notify', '');
