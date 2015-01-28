/*                                                                     -*-c++-*-
Copyright (C) 2015 Runtime Revolution Ltd.

This file is part of LiveCode.

LiveCode is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License v3 as published by the Free
Software Foundation.

LiveCode is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
for more details.

You should have received a copy of the GNU General Public License
along with LiveCode.  If not see <http://www.gnu.org/licenses/>.  */

#include <foundation.h>
#include <foundation-system.h>
#include <foundation-auto.h>
#include <script.h>

#if defined(__WINDOWS__)
#	include <windows.h>
#endif

/* Possible exit statuses used by lc-run */
enum {
	kMCRunExitStatusSuccess = 0,
	kMCRunExitStatusStartup = 124,
	kMCRunExitStatusBadArgs = 125,
	kMCRunExitStatusUncaughtError = 126,
};

struct MCRunConfiguration
{
	MCStringRef m_filename;
};

static void MCRunUsage (int p_exit_status) ATTRIBUTE_NORETURN;
static void MCRunStartupError (void) ATTRIBUTE_NORETURN;
static void MCRunHandlerError (void) ATTRIBUTE_NORETURN;
static void MCRunBadOptionError (MCStringRef p_arg) ATTRIBUTE_NORETURN;
static void MCRunBadOptionArgError (MCStringRef p_option, MCStringRef p_optarg) ATTRIBUTE_NORETURN;
static void MCRunPrintMessage (FILE *p_stream, MCStringRef p_message);


/* ----------------------------------------------------------------
 * Error helper functions
 * ---------------------------------------------------------------- */

/* Print a message if no arguments are provided */
static void
MCRunUsage (int p_exit_status)
{
	fprintf (stderr,
"Usage: lc-run [OPTIONS] [--] LCMFILE [ARGS ...]\n"
"\n"
"Run a compiled Modular Livecode bytecode file.\n"
"\n"
"Options:\n"
"  -h, --help           Print this message.\n"
"  --                   Treat next argument as bytecode filename.\n"
"\n"
"Any ARGS are available in \"the command arguments\".\n"
"\n"
"Report bugs to <http://quality.runrev.com/>\n"
	         );
	exit (p_exit_status);
}

/* Print an error message if an error occurs while starting the
 * LiveCode runtime */
static void
MCRunStartupError (void)
{
	MCAutoStringRef t_message, t_reason;
	MCErrorRef t_error;

	if (MCErrorCatch (t_error))
		t_reason = MCErrorGetMessage (t_error);
	else
		/* UNCHECKED */ MCStringCopy (MCSTR("Unknown error"), &t_reason);

	/* UNCHECKED */ MCStringFormat (&t_message, "ERROR: %@\n", *t_reason);

	MCRunPrintMessage (stderr, *t_message);
	exit (kMCRunExitStatusStartup);
}

/* Print an error message if an uncaught error occurs in the LiveCode
 * handler */
static void
MCRunHandlerError (void)
{
	MCAutoStringRef t_message, t_reason;
	MCErrorRef t_error;

	if (MCErrorCatch (t_error))
		t_reason = MCErrorGetMessage (t_error);
	else
		/* UNCHECKED */ MCStringCopy (MCSTR("Unknown error"), &t_reason);

	/* UNCHECKED */ MCStringFormat (&t_message,
	                                "ERROR: Uncaught error: %@\n",
	                                *t_reason);

	MCRunPrintMessage (stderr, *t_message);
	exit (kMCRunExitStatusUncaughtError);
}

/* Print an error message due to an unrecognised command-line
 * option */
static void
MCRunBadOptionError (MCStringRef p_arg)
{
	MCAutoStringRef t_message;
	/* UNCHECKED */ MCStringFormat (&t_message,
	                                "ERROR: Unknown option '%@'\n\n",
	                                p_arg);

	MCRunPrintMessage (stderr, *t_message);
	MCRunUsage (kMCRunExitStatusBadArgs);
}

static void
MCRunBadOptionArgError (MCStringRef p_option,
                        MCStringRef p_optarg)
{
	MCAutoStringRef t_message;
	if (NULL == p_optarg)
		/* UNCHECKED */ MCStringFormat (&t_message, "ERROR: Missing argument for option '%@'\n\n", p_option);
	else
		/* UNCHECKED */ MCStringFormat (&t_message, "ERROR: Bad argument '%@' for option '%@'\n\n", p_optarg, p_option);

	MCRunPrintMessage (stderr, *t_message);
	MCRunUsage (kMCRunExitStatusBadArgs);
}

static void
MCRunPrintMessage (FILE *p_stream,
                   MCStringRef p_message)
{
	MCAssert (p_stream);
	MCAssert (p_message);

#if defined(__WINDOWS__)
	MCAutoStringRefAsCString t_sys;
#else
	MCAutoStringRefAsSysString t_sys;
#endif
	/* UNCHECKED */ t_sys.Lock (p_message);
	fprintf (p_stream, "%s", *t_sys);
}

/* ----------------------------------------------------------------
 * Command-line argument processing
 * ---------------------------------------------------------------- */

#define MC_RUN_STRING_EQUAL(s,c) \
	(MCStringIsEqualToCString ((s),(c),kMCStringOptionCompareExact))

static bool
MCRunParseCommandLine (int argc,
                       const char *argv[],
                       MCRunConfiguration & x_config)
{
#if defined(__WINDOWS__)
	if (!MCSCommandLineCaptureWindows())
		return false;
#else
	if (!MCSCommandLineCapture (argc, argv))
		return false;
#endif

	bool t_have_filename = false;
	bool t_accept_options = true;
	MCAutoStringRef t_filename;
	MCAutoProperListRef t_raw_args, t_args;

	if (!MCProperListCreateMutable (&t_args))
		return false;

	if (!MCSCommandLineGetArguments (&t_raw_args))
		return false;

	/* FIXME Once we have "real" command line arguments, process them
	 * in this loop. */
	uindex_t t_num_args = MCProperListGetLength (*t_raw_args);
	for (uindex_t t_arg_idx = 0; t_arg_idx < t_num_args; ++t_arg_idx)
	{
		MCValueRef t_arg_val, t_argopt_val;
		MCStringRef t_arg, t_argopt;

		t_arg_val = MCProperListFetchElementAtIndex (*t_raw_args, t_arg_idx);
		MCAssert (MCTypeInfoConforms (MCValueGetTypeInfo (t_arg_val),
		                              kMCStringTypeInfo));
		t_arg = (MCStringRef) t_arg_val;

		/* If there's an argument after the current one, fetch it as a possible
		 * option value. */
		uindex_t t_argopt_idx = t_arg_idx + 1;
		if (t_argopt_idx < t_num_args)
		{
			t_argopt_val = MCProperListFetchElementAtIndex (*t_raw_args,
			                                                t_argopt_idx);
			MCAssert (MCTypeInfoConforms (MCValueGetTypeInfo (t_argopt_val),
			                              kMCStringTypeInfo));
			t_argopt = (MCStringRef) t_argopt_val;
		}
		else
		{
			t_argopt = NULL;
		}

		if (t_accept_options)
		{
			if (MC_RUN_STRING_EQUAL (t_arg, "--help") ||
			    MC_RUN_STRING_EQUAL (t_arg, "-h"))
			{
				/* Print help message */
				MCRunUsage (kMCRunExitStatusSuccess);
			}

			if (MC_RUN_STRING_EQUAL (t_arg, "--"))
			{
				/* No more options */
				t_accept_options = false;
				continue;
			}

			if (MCStringBeginsWithCString (t_arg, (const char_t *) "-",
			                               kMCStringOptionCompareExact))
			{
				/* Don't accept any unrecognised options */
				MCRunBadOptionError (t_arg);
			}
		}

		/* If we haven't got a filename yet, this argument must be it.
		 * Otherwise, queue any remaining arguments to pass as "the
		 * command arguments". */
		if (!t_have_filename)
		{
			t_filename = MCValueRetain (t_arg);
			t_have_filename = true;
			t_accept_options = false;
		}
		else
		{
			if (!MCProperListPushElementOntoBack (*t_args, t_arg_val))
				return false;
		}
	}

	/* Check that we found a bytecode filename */
	if (!t_have_filename)
	{
		fprintf(stderr, "ERROR: No bytecode filename specified.\n\n");
		MCRunUsage (kMCRunExitStatusBadArgs);
	}

	/* Set the "real" command name and arguments, accessible from
	 * LiveCode */
	if (!MCSCommandLineSetName (*t_filename))
		return false;
	if (!MCSCommandLineSetArguments (*t_args))
		return false;

	MCValueAssign (x_config.m_filename, *t_filename);

	return true;
}

/* ----------------------------------------------------------------
 * VM initialisation and launch
 * ---------------------------------------------------------------- */

static bool
MCRunLoadModule (MCStringRef p_filename,
                 MCScriptModuleRef & r_module)
{
	MCAutoDataRef t_module_data;
	MCAutoValueRefBase<MCStreamRef> t_stream;
	MCAutoValueRefBase<MCScriptModuleRef> t_module;

	if (!MCSFileGetContents (p_filename, &t_module_data))
		return false;

	if (!MCMemoryInputStreamCreate (MCDataGetBytePtr (*t_module_data),
	                                MCDataGetLength (*t_module_data),
	                                &t_stream))
		return false;

	if (!MCScriptCreateModuleFromStream (*t_stream, &t_module))
		return false;

	if (!MCScriptEnsureModuleIsUsable (*t_module))
		return false;

	r_module = MCValueRetain(*t_module);
	return true;
}


/* ----------------------------------------------------------------
 * Main program
 * ---------------------------------------------------------------- */

int
main (int argc,
      const char *argv[])
{
	/* Initialise the libraries. We need these for any further processing. */
	MCInitialize();
	MCSInitialize();
	MCScriptInitialize();

	/* Defaults */
	MCRunConfiguration t_config;
	t_config.m_filename = MCValueRetain (kMCEmptyString);

	/* ---------- Process command-line arguments */
	if (!MCRunParseCommandLine (argc, argv, t_config))
		MCRunStartupError();

	/* ---------- Start VM */
	MCAutoValueRefBase<MCScriptModuleRef> t_module;
	MCAutoValueRefBase<MCScriptInstanceRef> t_instance;
	MCAutoValueRef t_ignored_retval;

	if (!MCRunLoadModule (t_config.m_filename, &t_module))
		MCRunStartupError();

	if (!MCScriptCreateInstanceOfModule (*t_module, &t_instance))
		MCRunStartupError();

	if (!MCScriptCallHandlerOfInstance(*t_instance, MCNAME("main"), NULL, 0,
	                                   &t_ignored_retval))
		MCRunHandlerError();

	MCScriptFinalize();
	MCSFinalize();
	MCFinalize();

	exit (0);
}
