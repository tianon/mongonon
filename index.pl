#!/usr/bin/perl -w

use strict;
use warnings;

use open qw(:utf8 :std);

use CGI;
use CGI::Carp qw(fatalsToBrowser);

use POSIX;
use boolean;
use MongoDB;
use MongoDB::Code;
use JSON;

local $" = '';

*MongoDB::Code::TO_JSON = sub {
	my $self = shift;
	
	return { '$function' => $self->{code} };
};

# this TO_JSON function will work excellent if my patch is integrated into MongoDB
# see https://rt.cpan.org/Public/Bug/Display.html?id=60161
*boolean::TO_JSON = sub {
	my $self = shift;
	
	return (
		$self
		? JSON::true
		: JSON::false
	);
};

sub jsonToMongo {
	my $obj = shift;
	
	if (ref $obj eq 'HASH') {
		if (exists $obj->{'$oid'}) {
			$obj = MongoDB::OID->new(value => $obj->{'$oid'});
		}
		elsif (exists $obj->{'$function'}) {
			$obj->{'$function'} =~ s/\r\n|\r/\n/g;
			$obj = MongoDB::Code->new(code => $obj->{'$function'});
		}
		else {
			for my $key (keys %$obj) {
				$obj->{$key} = jsonToMongo($obj->{$key});
			}
		}
	}
	
	if (JSON::is_bool($obj)) {
		$obj = (
			$obj
			? boolean::true
			: boolean::false
		);
	}
	
	return $obj;
}

my $config = {
	indent => 2,
	sort => JSON::true,
	relaxed => JSON::true,
	mongo => {
		host => 'mongodb://localhost:27017',
	},
	perPage => 10,
	navbarContext => 5,
};

my $q = CGI->new;

print $q->header(
	-type => 'text/html',
	-charset => 'utf-8',
);

my $css = <<'CSS';
body {
	font-family: Arial, Helvetica, Verdana, sans-serif;
	font-size: 14px;
	padding: 0px;
	margin: 1em;
	background-color: white;
	color: black;
}

.json {
	font-family: monospace;
	white-space: pre;
}

ul, li {
	list-style: none outside none;
	padding: 0px;
	margin: 0px;
}

li {
	display: block;
	margin: 0.5em;
}

li a {
	padding: 0px;
	margin: 0px;
	text-decoration: none;
	color: #3c3;
	font-weight: bold;
}

li a:hover {
	background-color: #393;
}

li a, li .json {
	display: inline-block;
	padding: 0.3em;
	border: 1px dotted black;
}

ul.databases, ul.collections,
ul.databases li, ul.collections li {
	display: inline;
}

li .actionables {
	display: inline-block;
	text-align: right;
	vertical-align: top;
}

li .actionables a {
	margin-right: 0.1em;
	margin-bottom: 0.1em;
}
CSS

print $q->start_html(
	-title => 'mongonon',
	-encoding => 'utf-8',
	-head => [
		"<style type=\"text/css\">\n$css</style>",
	],
);

print $q->h1('mongonon');

my $json = JSON->new->utf8;

$json = $json->allow_blessed;
$json = $json->convert_blessed;
$json = $json->allow_nonref;

if ($config->{indent}) {
	$json = $json->indent->indent_length($config->{indent});
	$json = $json->space_after;
}

if ($config->{sort}) {
	$json = $json->canonical;
}

if ($config->{relaxed}) {
	$json = $json
	->relaxed
	->allow_singlequote
	->allow_barekey
	->allow_bignum
	->loose;
}

my $virginJson = JSON->new->utf8;
$virginJson = $virginJson->allow_blessed;
$virginJson = $virginJson->convert_blessed;
$virginJson = $virginJson->allow_nonref;

my $conn = MongoDB::Connection->new(%{ $config->{mongo} });

sub jsonDiv {
	my $obj = shift;
	
	return $q->div({
			-class => 'json',
		},
		$q->escapeHTML($json->encode($obj)),
	);
}

sub url {
	my @url = ();
	for (my $i = 0; $i < @_; $i += 2) {
		my ($key, $val) = @_[$i .. $i + 1];
		push @url, $q->escape($key) . '=' . $q->escape($val);
	}
	return $q->url(
		-relative => 1,
		-rewrite => 0,
	) . '?' . join ';', @url;
}

sub queryView {
	my $cursor = shift;
	my $urlArgs = shift || [];
	
	my $perPage = $q->param('per') || 0;
	$perPage = $config->{perPage} if $perPage < 1;
	
	my $total = $cursor->count;
	my $totalPages = POSIX::ceil($total / $perPage);
	
	my $page = $q->param('page') || 0;
	$page = $totalPages if $page > $totalPages;
	$page = 1 if $page < 1;
	
	unless ($total) {
		print $q->div({ -class => 'error' }, 'no items to display');
		return;
	}
	
	my $navDisplayContext = $config->{navbarContext};
	
	my $navMin = $page - $navDisplayContext;
	$navMin = 1 if $navMin < 1;
	my $navMax = $page + $navDisplayContext;
	$navMax = $totalPages if $navMax > $totalPages;
	
	my @links = ();
	push @links, ('&laquo; first', 1);
	push @links, ('&lt; prev', $page - 1);
	push @links, ($_, $_) for $navMin .. $navMax;
	push @links, ('next &gt;', $page + 1);
	push @links, ('last &raquo;', $totalPages);
	
	my @navbar = "page $page of $totalPages";
	for (my $i = 0; $i < @links; $i += 2) {
		my ($text, $num) = @links[$i .. $i + 1];
		if (
			$page == $num
			|| $num < 1
			|| $num > $totalPages
		) {
			push @navbar, $text;
		}
		else {
			push @navbar, $q->a({ -href => url(
						@$urlArgs,
						per => $perPage,
						page => $num,
					) }, $text);
		}
	}
	
	print $q->div({ -class => 'navbar' }, join ' ', @navbar);
	
	$cursor->reset->sort({ _id => 1 })->skip(($page - 1) * $perPage)->limit($perPage);
	
	my $returnTo = $q->url(
		-absolute => 1,
		-query => 1,
	);
	
	print $q->start_ul;
	while (my $obj = $cursor->next) {
		my $id = $virginJson->shrink->encode($obj->{_id});
		
		print $q->li(
			$q->div({ -class => 'actionables' },
				$q->div($q->a({ -href => url(
								@$urlArgs,
								id => $id,
								action => 'edit',
								returnTo => $returnTo,
							) }, 'edit')),
				$q->div($q->a({ -href => url(
								@$urlArgs,
								id => $id,
								action => 'delete',
								returnTo => $returnTo,
							) }, 'delete')),
			),
			jsonDiv($obj),
		);
	}
	print $q->end_ul;
	
	return;
}

sub processAction {
	my $db = shift;
	my $col = shift;
	my $id = shift;
	
	$id = jsonToMongo($id) if $id;
	
	my $action = $q->param('action');
	return 0 unless $action;
	
	my $returnTo = $q->param('returnTo');
	$returnTo = url(
		db => $db->name,
		col => $col->name,
	) unless $returnTo;
	
	print $q->h3($q->a({ -href => $returnTo }, '&laquo; return'));
	
	if ($action eq 'delete') {
		if ($id) {
			$col->remove({ _id => $id }, { just_one => 1 })
				and print $q->div('success') or print $q->div('failure');
			return 1;
		}
		# TODO allow deleting entire collections and databases here
	}
	elsif ($action eq 'edit' && $id) {
		my $obj = $col->find_one({ _id => $id });
		return 0 unless $obj;
		
		if (my $data = $q->param('data')) {
			$data = jsonToMongo($json->decode($data));
			$col->update({ _id => $id }, $data)
				and print $q->div('success') or print $q->div('failure');
			
			return 1;
		}
		else {
			print $q->start_form(
				-method => 'post',
				-action => $q->self_url,
				-enctype => 'application/x-www-form-urlencoded',
			);
			
			print $q->hidden('db', $db->name);
			print $q->hidden('col', $col->name);
			print $q->hidden('id', $virginJson->shrink->encode($id));
			print $q->hidden('action', $action);
			print $q->hidden('returnTo', $returnTo);
			
			print $q->div($q->textarea('data', $json->encode($obj), 25, 80));
			
			print $q->div($q->submit('Save'));
			
			print $q->end_form;
			
			return 1;
		}
	}
	
	return 0;
}

if (my $dbName = $q->param('db')) {
	my $db = $conn->get_database($dbName);
	
	if (my $colName = $q->param('col')) {
		my $col = $db->get_collection($colName);
		
		print $q->h2('data of ', $dbName, ' &raquo; ', $colName);
		
		if (my $id = $q->param('id')) {
			$id = $json->decode($id);
			$id = jsonToMongo($id);
			
			unless (processAction($db, $col, $id)) {
				print $q->h3($q->a({ -href => url(
								db => $dbName,
							) }, '&laquo; return to collection data'));
				
				my $cursor = $col->find({ _id => $id });
				queryView($cursor, [
					db => $dbName,
					col => $colName,
				]);
			}
		}
		else {
			print $q->h3($q->a({ -href => url(
							db => $dbName,
						) }, '&laquo; return to collections'));
			
			my $cursor = $col->find;
			queryView($cursor, [
				db => $dbName,
				col => $colName,
			]);
		}
	}
	else {
		print $q->h2('collections of ', $dbName);
		print $q->h3($q->a({ -href => url(
					) }, '&laquo; return to databases'));
		print $q->start_ul({ -class => 'collections' });
		for my $colName ($db->collection_names) {
			print $q->li($q->a({ -href => url(
							db => $dbName,
							col => $colName,
						) }, $q->escapeHTML($colName)));
		}
		print $q->end_ul;
	}
}
else {
	print $q->h2('databases');
	print $q->start_ul({ -class => 'databases' });
	for my $dbName ($conn->database_names) {
		print $q->li($q->a({ -href => url(
						db => $dbName,
					) }, $q->escapeHTML($dbName)));
	}
	print $q->end_ul;
}

print $q->end_html;
