#!/usr/bin/perl

use strict;
use warnings;

use Time::HiRes qw/gettimeofday tv_interval/;
our $begin_time = [gettimeofday];

require '/home/ajm/finance/common.pl';
require '/home/ajm/finance/XHTMLPP.pm'; # my bug-fixed version of the HTML pretty printer module

use CGI qw/:all *table *dl *tr *td *ul *div *tbody *tfoot *thead/;
use CGI::Carp('fatalsToBrowser');
$CGI::POST_MAX = 1024 * 100; # max 100K posts
$CGI::DISABLE_UPLOADS = 1; # no uploads

use POSIX qw/strftime/;
use Data::Dumper;
use Number::Format;
use Time::ParseDate;
use HTML::TreeBuilder;

our $VERSION = '1.0';
our $TITLE = 'Beehive Finance';
our $ENCODING = 'utf-8';

our $cgi;
our $dbh;
our $output;
our $script_name;

our %streams;
our $query_select_streams;
our $query_stream;
our $query_lastval;

our %base_object_registry = (
	'income'	=> \&make_income_form,
	'expense'	=> \&make_expense_form,
	'stream'	=> \&make_stream_form,
);

our %form_input_registry = (
	'text'			=> {
		'assert_valid'	=> \&assert_valid_form_input_text,
		'load'		=> \&load_form_input_text,
		'make_html'	=> \&make_form_input_text_html,
	},
	'label'			=> {
		'assert_valid'	=> \&assert_valid_form_input_label,
		'load'		=> \&load_form_input_label,
		'make_html'	=> \&make_form_input_label_html,
	},
	'currency'		=> {
		'assert_valid'	=> \&assert_valid_form_input_currency,
		'load'		=> \&load_form_input_currency,
		'make_html'	=> \&make_form_input_currency_html,
	},
	'date'			=> {
		'assert_valid'	=> \&assert_valid_form_input_date,
		'load'		=> \&load_form_input_date,
		'make_html'	=> \&make_form_input_date_html,
	},
	'select'		=> {
		'assert_valid'	=> \&assert_valid_form_input_select,
		'load'		=> \&load_form_input_select,
		'make_html'	=> \&make_form_input_select_html,
	},
	'radioset'		=> {
		'assert_valid'	=> \&assert_valid_form_input_radioset,
		'load'		=> \&load_form_input_radioset,
		'make_html'	=> \&make_form_input_radioset_html,
	},
);

sub make_header_html() {
	return start_html(
			-title		=> $TITLE,
			-lang		=> 'en_AU',
			-encoding	=> $ENCODING,
			-style		=> [
				{ -src => '/css/style.css' },
				{ -src => '/css/jquery.datepick.css' },
			], 
			-script		=> [
				{ -src => '/javascript/d3.v3.min.js' },
				{ -src => '/javascript/jquery.min.js' },
				{ -src => '/javascript/jquery.plugin.js' },
				{ -src => '/javascript/jquery.datepick.js' },
			],
		)
		.h1(escapeHTML($TITLE))
		.start_div({-class=>'content'}); 
}

sub make_footer_html() {
	my $query_db_schema = $dbh->prepare("SELECT value FROM config WHERE name='schema_version'") or die;
	$query_db_schema->execute() or die;
	die if $query_db_schema->rows != 1;
	my ($db_schema) = $query_db_schema->fetchrow_array() ;
	$query_db_schema->finish();	

	my $elapsed = tv_interval($begin_time);

	return end_div().div({-id=>'footer'},
		div({-class=>'center_div'}, img({-src=>'/images/bbb.jpg', -alt=>'buzz',-title=>'buzz', -style=>'margin: 10px; border: 4px solid grey;'})).
		 p(
		join (' &mdash; ', ( 
			escapeHTML($ENV{'SCRIPT_NAME'}),
			"frontend version <code>$VERSION</code>",
			"database schema <code>$db_schema</code>",
			a({-href=>'http://validator.w3.org/check?uri=referer'}, 'valid XHTML 1.1'),
			'<code>ajm@axdf.net</code>',
			"$elapsed sec"
		))
	)).end_html();
}

sub prep_queries() {
	$query_select_streams = $dbh->prepare('
		SELECT  *
		FROM    finance.stream
	') or die "query_select_streams: $DBI::errstr";

	$query_stream = $dbh->prepare('
		SELECT  *
		FROM	finance.stream
		WHERE	id = ?
	') or die "query_stream: $DBI::errstr";
}

sub load_streams() {
	$query_select_streams->execute() or die;
	while (my $row = $query_select_streams->fetchrow_hashref()) {
		$streams{$row->{'id'}} = $row;
	}
	$query_select_streams->finish();

	# figure out full names
	foreach my $stream_id (keys %streams) {
		my $stream = $streams{$stream_id};

		my $name = $stream->{'name'};
		my $parent_id = $stream->{'parent_id'};
		my $parent_loop_detection = 0;
		while (defined($parent_id) && $parent_id > 0) {
			die if $parent_loop_detection++ > 50;
			die unless exists $streams{$parent_id};
			my $parent_stream = $streams{$parent_id};
			$name = $parent_stream->{'name'}.'.'.$name;
			$parent_id = $parent_stream->{'parent_id'};
		}

		$stream->{'full_name'} = $name;
	}
}

sub stream_id_to_full_name($) {
	my ($stream_id) = @_;
	die unless exists $streams{$stream_id};
	return $streams{$stream_id}->{'full_name'}; 
}

sub html_stream_name($) {
	my ($name) = @_;
	return span({-class=>'stream_name_span'}, escapeHTML($name));
}

sub format_currency($) {
	my ($currency) = @_;
	my $nf = new Number::Format();
	my $c = $nf->format_number($currency, 2);
	if ($c =~ /\.\d$/) {
		$c .= '0';
	}
	unless ($c =~ /\./) {
		$c .= '.00';
	}
	return $c;
}

sub html_stream_name($) {
	my ($stream_name) = @_;
	return span({-class=>'stream_name_span'}, escapeHTML($stream_name));
}

sub html_currency($) {
	my ($currency) = @_;
	return span({-class=>'currency_span'}, escapeHTML(format_currency($currency)));
}

sub assert_valid_form_input_text($) {
	my ($input) = @_;
	die 'text without max_length' unless exists $input->{'max_length'};
}

sub assert_valid_form_input_label($) {
	my ($input) = @_;
	# nothing to do here
}

sub assert_valid_form_input_currency($) {
	my ($input) = @_;

	# TODO
}

sub assert_valid_form_input_date ($) {
	my ($input) = @_;

	# TODO
}
sub assert_valid_form_input_select ($) {
	my ($input) = @_;

	# TODO
	die 'select without options' unless exists $input->{'options'};
	die 'options not array ref' unless ref($input->{'options'}) eq 'ARRAY';
}
sub assert_valid_form_input_radioset ($) {
	my ($input) = @_;
	# TODO

}

sub assert_valid_form($) {
	my ($form) = @_;
	die unless ref($form) eq 'HASH';
	foreach ('display_name', 'name', 'inputs') {
		die "form missing $_" unless exists $form->{$_};
	}

	die unless ref($form->{'inputs'}) eq 'ARRAY';
	foreach my $input (@{$form->{'inputs'}}) {
		die 'form input not HASH ref' unless ref($input) eq 'HASH';

		foreach ('type', 'name', 'default') {
			unless (exists $input->{$_}) {
				die sprintf('assert_valid_form: form %s: missing %s: { %s }', $form->{'name'}, $_, 
					join('; ', map { sprintf '%s=%s', $_, $input->{$_} } keys %$input));
			}
		}

 		unless (exists $form_input_registry{$input->{'type'}}) {
			die 'assert_valid_form: unknown input type: '.$input->{'type'};
		}

		die unless exists $form_input_registry{$input->{'type'}}->{'assert_valid'};
		die unless ref($form_input_registry{$input->{'type'}}->{'assert_valid'}) eq 'CODE';

		&{$form_input_registry{$input->{'type'}}->{'assert_valid'}}($input);

		if (exists $input->{'max_length'}) {
			die 'max_length not numeric' unless $input->{'max_length'} =~ /^\d+$/;
		}

		if (exists $input->{'validation'}) {
			die 'validation not ref to sub' unless ref($input->{'validation'}) eq 'CODE';
		}
	}
}

sub load_form($) {
	my ($form) = @_;
	my $output = { };

	assert_valid_form($form);

	foreach my $input (@{$form->{'inputs'}}) {
		next if $input->{'type'} eq 'label';

		my $input_id = sprintf('input_%s_%s', $form->{'name'}, $input->{'name'});

		my $value;
		if ($cgi->param($input_id)) {
			$value = $cgi->param($input_id);
		}
		else {
			$value = $input->{'default'};
		}

		if (exists $input->{'max_length'}) {
			if (length($value) > $input->{'max_length'}) {
				$value = substr($value, 0, $input->{'max_length'});
			}
		}

		if ($input->{'type'} eq 'select') {
			my %values = @{$input->{'options'}};
			unless (exists $values{$value}) {
				my $error_message = exists $input->{'error_message'} ? $input->{'error_message'} : sprintf('invalid %s', $input->{'name'});
				$output->{$input->{'name'}}->{'error'} = $error_message;
				$value = $input->{'default'};
			}
		}
		elsif ($input->{'type'} eq 'date') {
			my $error_message;
			($value, $error_message) = parsedate($value,
				VALIDATE	=> 1,
				PREFER_PAST	=> 1,
				DATE_REQUIRED	=> 1,
				UK		=> 1,
				WHOLE 		=> 1,	
			);			

			unless (defined($value)) {
				$output->{$input->{'name'}}->{'error'} = sprintf('invalid %s (%s)',
					$input->{'name'}, $error_message);
				$value = $input->{'default'};
			}
		}
		
		$output->{$input->{'name'}} = {
			'value' => $value,
		};
		
		if (exists $input->{'validation'}) {
			unless (&{$input->{'validation'}}($value)) {
				my $error_message = exists $input->{'error_message'} ? $input->{'error_message'} : sprintf('invalid %s', $input->{'name'});
				$output->{$input->{'name'}}->{'error'} = $error_message;
			}
		}
	}

	return $output;
}

sub make_form_static_html($;$) {
	my ($form, $values) = @_;
	die unless ref($form) eq 'HASH';
	unless (ref($values) eq 'HASH') {
		$values = {};
	}

	my $output;

	assert_valid_form($form);

	

	return $output;
}

sub make_input_id($$) {
	my ($form, $input) = @_;
	die unless ref($form) eq 'HASH';
	die unless ref($input) eq 'HASH';

	return sprintf('input_%s_%s', $form->{'name'}, $input->{'name'});
}

sub make_form_input_label_html($) {
	my ($args) = @_;
	return td($args->{'default_value'});
}

sub make_form_input_text_html($) {
	my ($args) = @_;

	if ($args->{'static'}) {
		return td(
			escapeHTML($args->{'default_value'})
			.hidden({
				name	=> $args->{'input_id'},
				value	=> $args->{'default_value'},
			})
		);
	}

	return td(textfield({
		name		=> $args->{'input_id'},
		class		=> $args->{'in_error'} ? 'input_text_error' : 'input_text',
		value		=> $args->{'default_value'},
		size		=> $args->{'input'}->{'display_length'},
		maxlength	=> $args->{'input'}->{'max_length'},
	}));
}

sub make_form_input_date_html($) {
	my ($args) = @_;

	die "bad date default " unless $args->{'default_value'} =~ /^\d{10}$/;
			
	my $default_date = strftime('%Y-%m-%d', localtime($args->{'default_value'}));

	if ($args->{'static'}) {
		return td({ -class => 'date_td' },
			$default_date
			.hidden({
				name	=> $args->{'input_id'},
				value	=> $args->{'default_value'},
			})
		);
	}

	return td(
		textfield({
			name		=> $args->{'input_id'},
			id		=> $args->{'input_id'},
			class		=> $args->{'in_error'} ? 'input_text_error' : 'input_text',
			value		=> $default_date,
			size		=> 15,
			maxlength	=> 15,
		}).
		qq|
			<script type="text/javascript">
				\$(function() {
					\$('#$args->{input_id}').datepick({
						showOnFocus: false, 
						showTrigger: '<button type="button" class="trigger"><img src="/images/calendar.gif" alt="Popup"></button>',
						defaultDate 		: '$default_date',
						fixedWeeks		: true,
						selectDefaultDate 	: true,
						dateFormat		: 'yyyy-mm-dd',
						showAnim		: '',
						constrainInput		: false,
					});
				});
			</script>
		|
	);
}

sub make_form_input_currency_html($) { 
	my ($args) = @_;

	if ($args->{'static'}) {
		return td({ -class => 'currency_td' }, 
			html_currency($args->{'default_value'})
			.hidden({
				name	=> $args->{'input_id'},
				value	=> $args->{'default_value'},
			})
		);
	}

	return td(textfield({
		name		=> $args->{'input_id'},
		class		=> $args->{'in_error'} ? 'input_currency_error' : 'input_currency',
		value		=> sprintf('%.2f', $args->{'default_value'}),
		size		=> 8,
		maxlength	=> $args->{'input'}->{'max_length'},
	}));
}

sub make_form_input_select_html($$$$) { 
	my ($args) = @_;

	if ($args->{'static'}) {
		my %opts = @{$args->{'input'}->{'options'}};
		my $disp = $args->{'default_value'};
		if (exists $opts{$args->{'default_value'}}) {
			$disp = $opts{$args->{'default_value'}};
		}
		
		return td(
			escapeHTML($disp)
			.hidden({
				name	=> $args->{'input_id'},
				value	=> $args->{'default_value'},
			})
		);
	}

	my @values;
	my %labels;

	my @opts = @{$args->{'input'}->{'options'}};
	while (@opts) {
		my $value = shift @opts;
		my $label = shift @opts;
		push @values, $value;
		$labels{$value} = $label;
	}

	return td(popup_menu(
		-name		=> $args->{'input_id'},
		-class		=> $args->{'in_error'} ? 'input_text_error' : 'input_text',
		-default	=> $args->{'default_value'},
		-values		=> \@values,
		-labels		=> \%labels,
	));
}

sub make_form_input_radioset_html($) { 
	my ($args) = @_;

	if ($args->{'static'}) {
		my $disp = $args->{'default_value'};

		foreach my $opt (@{$args->{'input'}->{'options'}}) {
			if ($disp eq $opt->{'value'}) {
				$disp = $opt->{'display_name'};
			}
		}

		return td(
			escapeHTML($disp)
			.hidden({
				name	=> $args->{'input_id'},
				value	=> $args->{'default_value'},
			})
		);
	}

	my $output = start_td().start_dl();

	my $selection = $args->{'default_value'};

	foreach my $opt (@{$args->{'input'}->{'options'}}) {	
		my $opt_id = sprintf(
			'input_%s_%s_%s',
			$args->{'form'}->{'name'},
			$args->{'input'}->{'name'},
			$opt->{'value'}
		);

		my $selected = '';
		if ($selection eq $opt->{'value'}) {
			$selected = 'checked="checked" selected="selected"';
		}

		$output .= dt(sprintf(
			'<input class="%s" type="radio" %s name="%s" value="%s" id="%s" /><label for="%s">%s</label>',
			$args->{'in_error'} ? 'input_radio_error' : 'input_radio',
			$selected,
			escapeHTML($args->{'input_id'}),
			escapeHTML($opt->{'value'}),
			escapeHTML($opt_id),
			escapeHTML($opt_id),
			escapeHTML($opt->{'display_name'}),
		));

		$output .= dd($opt->{'display_text'});
	}

	$output .= end_dl().end_td();
	
	return $output;	
}

sub make_form_html($;$$) {
	my ($form, $values, $static) = @_;
	die unless ref($form) eq 'HASH';
	unless (ref($values) eq 'HASH') {
		$values = {};
	}

	my $output;

	assert_valid_form($form);

	unless ($static) {
		$output .= h2(escapeHTML($form->{'display_name'}));

		$output .= start_form({
			name	=> 'form_'.$form->{'name'},
			method	=> 'POST',
			action	=> $ENV{'SCRIPT_NAME'},
		});
	}

	# print out any error messages
	my @errors;
	foreach my $input (@{$form->{'inputs'}}) {
		if (exists $values->{$input->{'name'}}) {
			if (exists  $values->{$input->{'name'}}->{'error'}) {
				push @errors, $values->{$input->{'name'}}->{'error'};
			}
		}	
	}

	# print out the form
	$output .= start_div({-class=>'center_div'}).start_table({
		class  => 'form_table',
		summary => sprintf('%s details form', $form->{'name'}),
	});

	if (@errors) {
		$output .= thead(Tr(td({-colspan=>2}, make_error_box_html(@errors))));
	}

	$output .= start_tbody();

	foreach my $input (@{$form->{'inputs'}}) {
		my $input_id = make_input_id($form, $input);

		my $display_name = $input->{'name'};
		if (exists $input->{'display_name'}) {
			$display_name = $input->{'display_name'};
		}
		
		my $in_error = 0;
		if (exists $values->{$input->{'name'}}) {
			if (exists $values->{$input->{'name'}}->{'error'}) {
				$in_error = 1;
			}
		}

		my $default_value = '';
		if (exists $values->{$input->{'name'}}) {
			$default_value = $values->{$input->{'name'}}->{'value'};
		}
		elsif (exists $input->{'default'}) {
			$default_value = $input->{'default'};
		}

		die unless exists $form_input_registry{$input->{'type'}};
		die unless ref($form_input_registry{$input->{'type'}}) eq 'HASH';
		die unless exists $form_input_registry{$input->{'type'}}->{'make_html'};
		die unless ref($form_input_registry{$input->{'type'}}->{'make_html'}) eq 'CODE';

		my $input_html = &{$form_input_registry{$input->{'type'}}->{'make_html'}}({
			default_value	=> $default_value,
			static		=> $static,
			form		=> $form,
			input		=> $input,
			in_error	=> $in_error,
			input_id	=> $input_id,
		});

		$output .= Tr(td({ -class => 'form_label_td' }, escapeHTML($display_name)).$input_html); 
	}

	unless ($static) {
		$output .= Tr(td('&nbsp;'),td(
			submit({
				-class		=> 'submit_button',
				-value		=> 'SUBMIT',
			}).
			hidden({
				-name		=> 'sub',
				-default	=> $form->{'name'},
				-override	=> 1,
			})
		));
	}

	$output .= end_tbody().end_table().end_div();

	unless ($static) {
		$output .= end_form();
	}

	return $output;
}

sub valid_budget_template_id($) {
	my ($budget_template_id) = @_;

	if ($budget_template_id !~ /^\d+$/) {
		return 0;
	}

	if ($budget_template_id == 0) {
		return 1;
	}

	my $query_select_budget_template = $dbh->prepare('
		SELECT		*
		FROM		budget_template
		WHERE		id = ?
	') or die $DBI::errstr;

	$query_select_budget_template->execute($budget_template_id) or die $DBI::errstr;
	if ($query_select_budget_template->rows != 1) {
		$query_select_budget_template->finish();
		return 0;
	}

	$query_select_budget_template->finish();
	return 1;
}

sub expense_form_handler($) {
	my ($form_values) = @_;
	die unless ref($form_values) eq 'HASH';

	my $query_insert_expense = $dbh->prepare('
		INSERT INTO	expense (date, amt, "desc", stream_id) 
		VALUES		(?, ?, ?, ?)
	') or die $DBI::errstr;
	
	my $insert_date = strftime('%Y-%m-%d', localtime($form_values->{'date'}->{'value'}));
	
	$query_insert_expense->execute(
		$insert_date,
		$form_values->{'amount'}->{'value'},
		$form_values->{'description'}->{'value'},
		$form_values->{'stream'}->{'value'}
	) or die $DBI::errstr;

	$query_insert_expense->finish();

	return {
		output	=> '',
		error	=> 0,
		newid	=> db_lastval(),
	};
}

sub stream_form_handler($) {
	my ($form_values) = @_;
	die unless ref($form_values) eq 'HASH';

	my $query_insert_stream = $dbh->prepare('
		INSERT INTO	stream (name, parent_id, comment)
		VALUES		(?, ?, ?)
	') or die $DBI::errstr;

	$query_insert_stream->execute(
		$form_values->{'name'}->{'value'},
		$form_values->{'parent'}->{'value'},
		$form_values->{'comment'}->{'value'}
	) or die $DBI::errstr;
	$query_insert_stream->finish();
	
	return {
		output	=> '',
		error	=> 0,
		newid	=> db_lastval(),
	};
}

sub income_form_handler($) {
	my ($form_values) = @_;
	die unless ref($form_values) eq 'HASH';
	
	my @errors;
	my $budget_template;

	my $query_insert_income = $dbh->prepare('
		INSERT INTO	income (amt, source, date)
		VALUES		(?, ?, ?)
	') or die $DBI::errstr;

	# TODO: check amt >= total budget	

	db_begin_transaction();

	$query_insert_income->execute(
		$form_values->{'amt'}->{'value'}, 
		$form_values->{'from'}->{'value'},
		'NOW()'
	) or die;	
	$query_insert_income->finish();

	my $income_id = db_lastval();

	if ($form_values->{'budget'}->{'value'} > 0) {

		my $query_insert_budget = $dbh->prepare('
			INSERT INTO	budget (date_start, date_end, name, comments)
			VALUES		(?, ?, ?, ?)
		') or die $DBI::errstr;

		my $query_insert_budget_item = $dbh->prepare('
			INSERT INTO	budget_item (budget_id, stream_id, amt)
			VALUES		(?, ?, ?)
		') or die $DBI::errstr;

		my $query_insert_income_budget = $dbh->prepare('
			INSERT INTO	income_budget (income_id, budget_id)
			VALUES		(?, ?)
		') or die $DBI::errstr;

		my $query_select_budget_template_item = $dbh->prepare('
			SELECT		*
			FROM		budget_template_item
			WHERE		budget_template_id = ? 
		') or die $DBI::errstr;

		my $query_select_budget_template = $dbh->prepare('
			SELECT		*
			FROM		budget_template
			WHERE		id = ?
		') or die $DBI::errstr;

		$query_select_budget_template->execute($form_values->{'budget'}->{'value'}) or die $DBI::errstr;
		die unless $query_select_budget_template->rows == 1;
		my ($budget_template) = $query_select_budget_template->fetchrow_hashref() or die;
		$query_select_budget_template->finish();

		$query_select_budget_template_item->execute($budget_template->{'id'}) or die;

		$query_insert_budget->execute('NOW()', 'NOW()+14d', $budget_template->{'name'}, $budget_template->{'comments'}) or die;
		$query_insert_budget->finish();

		my $budget_id = db_lastval();

		$query_insert_income_budget->execute($income_id, $budget_id) or die;
		$query_insert_income_budget->finish();

		while (my $item = $query_select_budget_template_item->fetchrow_hashref()) {
			$query_insert_budget_item->execute($budget_id, $item->{'stream_id'}, $item->{'amt'}) or die;
			$query_insert_budget_item->finish();
		}

		$query_select_budget_template_item->finish();
	}

	db_commit_transaction();

	return {
		output	=> '',
		error	=> 0,
		newid	=> $income_id,
	};
}

sub currency_validation { /^\d+(\.(\d+)?)?$/ }

sub make_stream_form() {
	my $stream_form = {
		'name'		=> 'stream',
		'display_name'	=> 'stream',
		'handler'	=> \&stream_form_handler,
		'inputs'	=> [
			{
				'type'			=> 'text',
				'name'			=> 'name',
				'default'		=> '',
				'max_length'		=> 20,
			},
			{
				'type'			=> 'select',
				'name'			=> 'parent',
				'options'		=> [
					0 => '(no parent; root stream)',
					map {
						($_, $streams{$_}->{'full_name'})
					}
					sort {
						$streams{$a}->{'full_name'} cmp $streams{$b}->{'full_name'}
					}
					keys %streams
				],
			},
		],
	};

	return $stream_form;
}

sub make_expense_form($) {
	my ($expense_id) = @_;
	die unless $expense_id =~ /^\d+$/;
	
	my $default_date = time();
	my $default_amount = 0;
	my $default_stream = 0;
	my $default_description = '';

	if ($expense_id > 0) {
		my $query_expense = $dbh->prepare('
			SELECT		date, amt, stream_id, "desc"
			FROM		expense
			WHERE		id = ?
		') or die $DBI::errstr;

		$query_expense->execute($expense_id);
		die unless $query_expense->rows == 1;
		($default_date, $default_amount,  $default_stream, $default_description) = $query_expense->fetchrow_array();
		$query_expense->finish();
	}

	my $expense_form = {
		'name'		=> 'expense',
		'display_name'	=> 'add expense',
		'handler'	=> \&expense_form_handler,
		'inputs'	=> [
			{
				'type'			=> 'date',
				'name'			=> 'date',
				'default'		=> $default_date,
			},	
			{
				'type'			=> 'currency',
				'name'			=> 'amount',
				'default'		=> $default_amount,
				'validation'		=> sub { $_[0] > 0 },
			},
			{
				'type'			=> 'select',
				'name'			=> 'stream',
				'default'		=> $default_stream,
				'validation'		=> sub { $_[0] > 0 },
			},
			{
				'type'			=> 'text',
				'name'			=> 'description',
				'default'		=> $default_description,
				'max_length'		=> 200,
			},
		],
	};

	my $stream_index = 2;
	die unless $expense_form->{'inputs'}[$stream_index]->{'name'} eq 'stream';
	$expense_form->{'inputs'}[$stream_index]->{'options'} = [ 
		0 => '', 
		map {
			($_, $streams{$_}->{'full_name'})
		}
		sort {
			$streams{$a}->{'full_name'} cmp $streams{$b}->{'full_name'}
		}
		keys %streams
	];

	if ($expense_id > 0) {
		$expense_form->{'display_name'} = 'edit expense';
		unshift @{$expense_form->{'inputs'}}, {
			'type'		=> 'label',
			'name'		=> 'id',
			'default'	=> "<strong><code>$expense_id</code></strong>",
		};
	}
	
	return $expense_form;
}


sub make_income_form($) {
	my ($income_id) = @_;

	my $amount_default = 0;
	my $from_default = '';
	my $budget_default = 0;
		
	if ($income_id > 0) {
		my $query_income = $dbh->prepare('
			SELECT		amt, source
			FROM		income
			WHERE		id = ?
		') or die $DBI::errstr;
		$query_income->execute($income_id) or die $DBI::errstr;
		die unless $query_income->rows == 1;
		($amount_default, $from_default) = $query_income->fetchrow_array();
		$query_income->finish();

		my $query_budget = $dbh->prepare('
			SELECT		budget_id
			FROM		income_budget
			WHERE		income_id = ?
		') or die $DBI::errstr;
		$query_budget->execute($income_id) or die $DBI::errstr;
		if ($query_budget->rows > 1) {
			$query_budget->finish();
			return make_info_box_html('Frontend version only support 1-to-1 relation between budget and income');
		}
		if ($query_budget->rows == 1) {
			($budget_default) = $query_budget->fetchrow_array();
		}
		$query_budget->finish();
	}

	my $income_form = {
		'name'		=> 'income',
		'display_name'	=> 'add income',
		'handler'	=> \&income_form_handler,
		'inputs'	=> [
			{
				'type'			=> 'currency',
				'name'			=> 'amount',
				'default'		=> $amount_default,
			},
			{ 
				'type'			=> 'text',
				'name'			=> 'from',
				'default'		=> $from_default,
				'max_length'		=> 20,
				'display_length'	=> 20,
			},
		],
	};
	
	#
	# if this is a new income or existing income without budget, display budget linking options
	#
	if ($income_id == 0) {

		my $query_budget_templates = $dbh->prepare('
			SELECT		*
			FROM		budget_template
			ORDER BY	name
		') or die $DBI::errstr;

		my $query_budget_template_items = $dbh->prepare('
			SELECT		*
			FROM		budget_template_item
			WHERE		budget_template_item.budget_template_id = ?
		') or die $DBI::errstr;

		$query_budget_templates->execute() or die $DBI::errstr;

		my @opts;

		push @opts, {
			'display_name' 	=> 'no budget',
			'display_text' 	=> ':(',
			'value'		=> 0,
		};

		while (my $budget_template = $query_budget_templates->fetchrow_hashref()) {
			$query_budget_template_items->execute($budget_template->{'id'}) or die $DBI::errstr;

			my $dd_html = escapeHTML($budget_template->{'comments'})
				.start_table({
					-summary => 'Breakdown of this budget allocation into streams'
				})
				.thead(
					Tr(th('stream'), th('budget ($)'))
				)
				.start_tbody();

			my $row_num = 0;
			my $sum = 0;
			while (my $budget_template_item = $query_budget_template_items->fetchrow_hashref()) {
				$sum += $budget_template_item->{'amt'};
				my $full_stream_name = stream_id_to_full_name($budget_template_item->{'stream_id'}); 
				$dd_html .= Tr({ -class=> ++$row_num % 2 ? 'tr_even' : 'tr_odd' },
					td({-class=>'stream_name_td'}, html_stream_name($full_stream_name)), 
					td({-class=>'currency_td'}, html_currency($budget_template_item->{'amt'}))
				)."\n";
			}

			$dd_html .= end_tbody()
				.tfoot(
					Tr({ -class=> ++$row_num % 2 ? 'tr_even' : 'tr_odd' }, 
						td('TOTAL'),
						td({-class=>'currency_td'}, html_currency($sum))
					)
				)
				.end_table();

			push @opts, {
				'display_name'	=> $budget_template->{'name'},
				'display_text'	=> $dd_html,
				'value'		=> $budget_template->{'id'},
			};

			$query_budget_template_items->finish();
		}

		$query_budget_templates->finish();

		my $budget_radioset = {
			'type'		=> 'radioset',
			'name'		=> 'budget',
			'display_name'	=> 'attach budget',
			'default'	=> $budget_default,
			'options'	=> \@opts,
			'validation'	=> \&valid_budget_template_id,
			'max_length'	=> 4,
		};

		push @{$income_form->{'inputs'}}, $budget_radioset;
	}
	else {
		# there is an existing budget for this income, allow editing of the budget
		# don't support editing existing budget at the moment
		$income_form->{'display_name'} = 'edit income';

		unshift @{$income_form->{'inputs'}}, {
			'type'			=> 'label',
			'name'			=> 'id',
			'default'		=> "<strong><code>$income_id</code></strong>",
		},
	}

	return $income_form;
}

sub trim($) {
	my ($output) = @_;
	$output =~ s/^\s*|\s*$//;
	return $output;
}

sub make_info_box_html($) {
	return div({-class=>'info_box'}, @_);
}

sub make_error_box_html($) {
	return div({-class=>'error_box'}, ul(li([ map { escapeHTML($_) } @_ ])));
}

sub db_lastval() {
	unless ($query_lastval) {
		$query_lastval = $dbh->prepare('
			SELECT	lastval() as id
		') or die "lastval: $DBI::errstr";
	}

	$query_lastval->execute() or die "lastval: $DBI::errstr";
	my ($newid) = $query_lastval->fetchrow_array();
	$query_lastval->finish();

	return $newid;
}

sub db_valid_id($$) {
	my ($table, $tuple_id ) = @_;
	die "db_valid_id: tuple_id[$tuple_id] invalid" unless $tuple_id =~ /^\d+$/;
	die unless $table =~ /^[a-z]+$/;
	
	my $query_tuple = $dbh->prepare("
		SELECT		id
		FROM		$table
		WHERE		id = ?
	") or die $DBI::errstr;
	eval {
		$query_tuple->execute($tuple_id);
	};
	if ($@) {
		$query_tuple->finish();
		return 0;
	}

	my $rval = $query_tuple->rows;
	$query_tuple->finish();

	return $rval;
}

sub db_begin_transaction() {
	$dbh->do('BEGIN') or die $DBI::errstr;
}

sub db_commit_transaction() {
	$dbh->do('COMMIT') or die $DBI::errstr;
}

sub do_form($) {
	my ($args) = @_;
	die unless ref($args) eq 'HASH';
	die unless exists $args->{'form'};
	die unless ref($args->{'form'}) eq 'HASH';
	die unless exists $args->{'form'}->{'name'};
	
	my $output;

	# if not a submission, then just present the blank form.
	if ($cgi->param('sub') ne $args->{'form'}->{'name'}) {
		$output .= make_form_html($args->{'form'});
		return {
			output	=> $output,
			error	=> 0,
		};
	}

	my $form_values = load_form($args->{'form'});
	die unless ref($form_values) eq 'HASH';

	# check for errors
	my @errors;
	foreach my $input_name (keys %$form_values) {
		my $input = $form_values->{$input_name};
		die unless ref($input) eq 'HASH';
		if (exists $input->{'error'}) {
			push @errors, $input->{'error'};
		}
	}

	if (@errors) {
		$output .= make_form_html($args->{'form'}, $form_values);
		return {
			output	=> $output,
			error	=> 1,
		};
	}

	# no errors, so pass off to the submission handler.
	my $form_submission_state = &{$args->{'form'}->{'handler'}}($form_values);
	die unless ref($form_submission_state) eq 'HASH';

	if ($form_submission_state->{'error'}) {
		return {
			output	=> $form_submission_state->{'output'},
			error	=> 1,
		};
	}

	my $newid_edit_html;
	if (exists $form_submission_state->{'newid'}) {
		if (db_valid_id($args->{'class'}, $form_submission_state->{'newid'})) {
			$newid_edit_html = br().a({-href=>'/'.$args->{'class'}.'/edit/'.$form_submission_state->{'newid'}}, escapeHTML("make corrections") );
		}
	}

	# form submission succeeded, display confirmation.
	return {
		output	=> make_form_html($args->{'form'}, $form_values, 1)
			.p(
				a({-href=>'/'.$args->{'class'}}, escapeHTML($args->{'class'}." list") )
				.$newid_edit_html
			),
		error 	=> 0,
	};
}

sub make_object_actions_td_html($$) {
	my ($class, $id) = @_;

	return td(a({-href=>sprintf('/%s/edit/%d', $class, $id)}, img({
			-src	=> '/images/edit.gif',
			-title  => 'edit',
			-alt	=> 'edit',	
		}))
		.'&nbsp;'
		.a({-href=>sprintf('/%s/delete/%d', $class, $id)}, img({ 
			-src	=> '/images/delete.gif',
			-title	=> 'delete',
			-alt	=> 'delete',
		})));
}

sub make_data_table_head_html($@) {
	my ($class, @cols) = @_;

	return start_div({-class=>'center_div'})
		.start_table({-class=>'data_table'})
		.thead(
			Tr(
				th({-colspan=>@cols + 1}, escapeHTML($class))
			)
			.Tr(
				th([map { escapeHTML($_) } @cols]),
				th(
					a({-href=>"/$class/add"}, img({
						-alt	=> 'add',
						-title	=> 'add',
						-src	=> '/images/add.gif',
					}) )
				)
			)
		)
		.start_tbody();
}

sub make_data_table_foot_html() {
 	return end_tbody().end_table().end_div();
}

sub make_home_page_html() {

	return make_expense_table_html();
}

sub make_expense_table_html() {
	my $output;

	my $query_expenses = $dbh->prepare('
		SELECT 		id, date, amt, stream_id, "desc"
		FROM		expense
		ORDER BY	date DESC,id DESC
	') or die $DBI::errstr;
	$query_expenses->execute() or die $DBI::errstr;	

	$output .= make_data_table_head_html('expense', 'id', 'date', 'amount', 'stream', 'description');

	my $row_num = 0;
	while (my $expense = $query_expenses->fetchrow_hashref()) {

		die unless exists $streams{$expense->{'stream_id'}};
		my $stream_full_name = $streams{$expense->{'stream_id'}}->{'full_name'};

		$output .= Tr({ -class=> ++$row_num % 2 ? 'tr_even' : 'tr_odd' },
			td({-class=>'id_td'}, $expense->{'id'}),
			td({-class=>'date_td'}, $expense->{'date'}),
			td({-class=>'currency_td'}, html_currency($expense->{'amt'})),
			td({-class=>'stream_name_td'}, html_stream_name($stream_full_name)),
			td({-class=>'description_td'}, escapeHTML($expense->{'desc'})),
			make_object_actions_td_html('expense', $expense->{'id'}),
		);
		
	}

	$output .= make_data_table_foot_html();

	$query_expenses->finish();

	return $output;
}

sub make_income_list_html() {
	my $output;

	my $query_income = $dbh->prepare('
		SELECT		*
		FROM		income
		ORDER BY	date DESC
	') or die $DBI::errstr;

	my $query_income_budget = $dbh->prepare('
		SELECT		budget.name as name,
				budget.comments as comments,
				sum(budget_item.amt) as total
		FROM		income_budget
		LEFT JOIN	budget
			    ON  budget.id = income_budget.budget_id
		LEFT JOIN	budget_item
			    ON	budget_item.budget_id = budget.id
		WHERE		income_budget.income_id = ?
		GROUP BY	budget.name, budget.comments
		ORDER BY	total DESC
	') or die $DBI::errstr;

	$output .= make_data_table_head_html('income', 'date', 'amount ($)', 'from', 'budget');

	$query_income->execute() or die;
	my $row_num = 0;
	while (my $income = $query_income->fetchrow_hashref()) {
		my @budget_data;

		$query_income_budget->execute($income->{'id'}) or die;
		while (my $budget = $query_income_budget->fetchrow_hashref()) {
			push @budget_data, sprintf('%s %s', 
				escapeHTML($budget->{'name'}), 
				html_currency($budget->{'total'})
			);
		}
		$query_income_budget->finish();

		my $budget_data = '-';
		if (@budget_data) {
			$budget_data = join('<br/>', @budget_data);
		}

		$output .= Tr({ -class=> ++$row_num % 2 ? 'tr_even' : 'tr_odd' },
			td({-class=>'date_td'}, escapeHTML($income->{'date'})),
			td({-class=>'currency_td'},html_currency($income->{'amt'})),
			td(escapeHTML($income->{'source'})),
			td($budget_data),
			make_object_actions_td_html('income', $income->{'id'}),
		);
	}
	$query_income->finish();

	$output .= make_data_table_foot_html();

	return $output;
}

sub make_stream_delete_html($) {
	my ($pathinfo) = @_;

	die unless $pathinfo =~ m{^/stream/delete/(\d+)$};
	my $stream_id = $1;

	unless (db_valid_id('stream', $stream_id)) {
		return make_error_box_html('Cant find that stream');
	}

	if ($cgi->param('sub') eq 'delete_stream') {
		my $query_delete_stream = $dbh->prepare('
			DELETE FROM	stream
			WHERE		id = ?
		') or die $DBI::errstr;

		$query_delete_stream->execute($stream_id) or die $DBI::errstr;
		$query_delete_stream->finish();

		return make_info_box_html('Stream deleted<br/>Return to Streams');
	}

	return form({
			name	=> 'form_delete_confirm',
			-action	=> $ENV{'SCRIPT_NAME'},
			-method	=> 'POST',
		},
		make_info_box_html(
			submit({
				-class		=> 'submit_button',
				-value		=> 'CONFIRM',
			}).
			hidden({
				-name		=> 'sub',
				-default	=> 'delete_stream',
				-override	=> 1,
			})
		)
	); 
}

sub make_object_action_html($) {
	my ($pathinfo) = @_;
	die unless $pathinfo =~ m{^/([a-z]+)/([a-z]+)(?:/(\d+))?$};
	my $object = $1;
	my $action = $2;
	my $id = $3 || 0;

	die unless exists $base_object_registry{$object};
	die unless $action eq 'add' or $action eq 'edit' or $action eq 'delete';

	unless ($action eq 'add') {
		unless (db_valid_id($object, $id)) {
			return make_error_box_html("Can't find that $object");
		}
	}

	my $form_status = do_form({
		class	=> $object,
		form	=> &{$base_object_registry{$object}}($id),
	});
	die unless ref($form_status) eq 'HASH';

	if ($form_status->{'error'}) {
		# form submission either failed or no data, so just present the form
		return $form_status->{'output'};
	}

	# form submission succeeded, so in addition to the confirmation message display something interesting
	return $form_status->{'output'};
}

sub tidy_print($) {
	my $tree = HTML::TreeBuilder->new_from_content($_[0]) or die;
	$tree->elementify();

	my $pp = XHTMLPP->new(
		'linelength' => 512,
		'quote_attr' => 1
	) or die;
	$pp->allow_forced_nl(1);

	print '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "/dtd/xhtml11.dtd">'."\n";
	foreach (@{$pp->format($tree)}) {
		print;
	}
}

sub allocate_subsystem() {

	my %subsystem_map = (
		'/'			=> \&make_home_page_html,
		'/cgi-bin/finance.pl'	=> \&make_home_page_html,
	);

	foreach my $object (sort keys %base_object_registry) {
		die unless $object =~ /^[a-z]+$/;
		$subsystem_map{"/$object/add"} = 
		$subsystem_map{"/$object/edit/(\\d+)"} =
		$subsystem_map{"/$object/delete/(\\d+)"} =
		\&make_object_action_html;
	}

	$script_name = $ENV{'SCRIPT_NAME'} || '';
	$script_name =~ s/^\/+/\//;

	foreach my $regex (sort keys %subsystem_map) {
		if ($script_name =~ m{^$regex$}) {
			return $subsystem_map{$regex};
		}
	}

	print qq|Status: 404 Not Found
Content-Type: text/html

<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>404 Not Found</title>
</head><body>
<h1>Not Found</h1>
<p>The requested URL $script_name was not found on this server.</p>
</body></html>
|;
	exit 0;
}


#
# driver
#
sub main() {

	my $subsystem = allocate_subsystem();

	$cgi = CGI->new;
	if (cgi_error()) {
		print header( -status => cgi_error() );
		exit 0;
	}

	print header( -charset => $ENCODING );

	$dbh = db_init();

	prep_queries(); 
	load_streams(); 

	$output .= make_header_html().&$subsystem($script_name, $output).make_footer_html(); 

	tidy_print($output);

	return 0;
}


#
# call driver
#
exit main();

