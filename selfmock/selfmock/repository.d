module selfmock.Repository;

import selfmock.util;
import selfmock.mockobject;
import selfmock.call;
import selfmock.arguments;
import tango.core.Variant;
import tango.io.Stdout;

version (MocksDebug)
	version = OrderDebug;

public class MockRepository
{
	// TODO: split this up somehow!
	private bool _allowDefaults = false;
	private ICall[] _calls = [];
	private bool _recording = true;
	private bool _ordered = false;
	private ICall _lastCall;
	private ICall _lastOrdered;

	private void checkLastCallSetup ()
	{
		if (_allowDefaults || _lastCall is null || _lastCall.hasAction)
		{
			return;
		}

		throw new MocksSetupException(
				"Last call: if you do not specify the AllowDefaults option, you need to return a value, throw an exception, execute a delegate, or pass through to base function. The call is: " ~ _lastCall.toString);
	}

	private void checkOrder (ICall current, ICall previous)
	{
		version (OrderDebug)
			writefln("CheckOrder: init");
		version (OrderDebug)
			writefln("CheckOrder: current: %s", selfmock.util.toString(current));
		if (current !is null)
			version (OrderDebug)
				writefln("CheckOrder: current.Last: %s", selfmock.util.toString(
						current.LastCall));
		version (OrderDebug)
			writefln("CheckOrder: previous: %s", selfmock.util.toString(previous));
		if (current !is null)
			version (OrderDebug)
				writefln("CheckOrder: previous.Next: %s", selfmock.util.toString(
						current.NextCall));
		if (current is null || (current.LastCall is null && previous !is null && previous.NextCall is null))
		{
			version (OrderDebug)
				writefln("CheckOrder: nothing to do, returning");
			return; // nothing to do
		}

		/* The user set up:
		 m.Expect(foo.bar(5)).Repeat(3, 4).Return(blah);
		 m.Expect(foo.bar(3)).Repeat(2).Return(blah);
		 So I need to track the last two calls.

		 Or:
		 m.Expect(baz.foobar)...
		 m.Expect(foo.bar(5)).Repeat(0, 2).Return(blah);
		 m.Expect(foo.bar(3)).Repeat(2).Return(blah);
		 Then, I basically have a linked list to traverse. And it must be
		 both ways.
		 */
		auto last = previous;
		while (last !is null && last.NextCall !is null)
		{
			version (OrderDebug)
				writefln("CheckOrder: checking forward");
			if (last.nextCall == cast(Object) current)
			{
				break;
			}
			if (last.repeat().min > 0)
			{
				// We expected this to be called between _lastCall and icall.
				version (OrderDebug)
					writefln("CheckOrder: got one");
				throwForwardOrderException(previous, current);
			}

			last = last.nextCall;
		}

		last = current;
		while (last !is null && last.lastCall !is null)
		{
			version (OrderDebug)
				writefln("CheckOrder: checking backward");
			if (last.lastCall == cast(Object) previous)
			{
				break;
			}
			if (last.repeat().min > 0)
			{
				// We expected this to be called between _lastCall and icall.
				version (OrderDebug)
					writefln("CheckOrder: got one");
				throwBackwardOrderException(previous, current);
			}

			last = last.lastCall;
		}
	}

	private void throwBackwardOrderException (ICall previous, ICall current)
	{
		char[]
				msg = "Ordered calls received in wrong order: \n" ~ "Before: " ~ selfmock.util.toString(
						current) ~ "\n" ~ "Expected: " ~ current.lastCall().toString ~ "\n" ~ "Actual: " ~ selfmock.util.toString(
						current);
		throw new ExpectationViolationException(msg);
	}

	private void throwForwardOrderException (ICall previous, ICall actual)
	{
		char[]
				msg = "Ordered calls received in wrong order: \n" ~ "After: " ~ selfmock.util.toString(
						previous) ~ "\n" ~ "Expected: " ~ previous.nextCall().toString ~ "\n" ~ "Actual: " ~ selfmock.util.toString(
						actual);
		throw new ExpectationViolationException(msg);
	}

public
{
	void allowDefaults (bool value)
	{
		_allowDefaults = value;
	}

	bool recording ()
	{
		return _recording;
	}

	void replay ()
	{
		checkLastCallSetup();
		_recording = false;
		_lastCall = null;
		_lastOrdered = null;
	}


	void backToRecord ()
	{
		_recording = true;
	}

	ICall lastCall ()
	{
		return _lastCall;
	}

	void ordered (bool value)
	{
		version (MocksDebug)
			writefln("SETTING ORDERED: %s", value);
		_ordered = value;
	}

	bool ordered ()
	{
		return _ordered;
	}

	void record (U...) (IMocked mocked, char[] name, U args, bool returns)
	{
		checkLastCallSetup();
		ICall call;
		// I hate having to check for an empty tuple.
		static if (U.length)
		{
			call = new Call(mocked, name, new Arguments!(U)(args));
		}
		else
		{
			call = new Call(mocked, name, new Arguments!(U)());
		}
		call.Void(!returns);

		if (_ordered)
		{
			call.ordered = true;
			call.lastCall = _lastOrdered;
			if (_lastOrdered !is null)
			{
				_lastOrdered.nextCall = call;
			}
			_lastOrdered = call;
		}

		_calls ~= call;
		_lastCall = call;
	}

	ICall match (U...) (IMocked mocked, char[] name, U args)
	{
		version (MocksDebug)
			writefln("about to match");
		auto match = new Call(mocked, name, new Arguments!(U)(args));
		version (MocksDebug)
			writefln("created call");

		foreach (icall; _calls)
		{
			version (MocksDebug)
				writefln("checking call");
			if (icall == match)
			{
				version (MocksDebug)
					writefln("found a match");
				icall.called();
				version (MocksDebug)
					writefln("called the match");
				if (icall.Ordered)
				{
					checkOrder(icall, _lastOrdered);
					_lastOrdered = icall;
				}

				_lastCall = icall;
				return icall;
			}
		}
		return null;
	}

	void verify ()
	{
		foreach (call; _calls)
		{
			if (!call.satisfied)
			{
				// TODO: eventually we'll aggregate these, but for now,
				// just quit on the first one.
				throw new ExpectationViolationException(call.toString());
			}
		}
	}

	version (MocksTest)
	{
		unittest {
			writef("repository record/replay unit test...");
			scope (failure)
				writefln("failed");
			scope (success)
				writefln("success");

			MockRepository r = new MockRepository();
			assert (r.recording());
			r.replay();
			assert (!r.recording());
			r.backToRecord();
			assert (r.recording());
		}

		unittest {
			writef("match object with no expectations unit test...");
			scope (failure)
				writefln("failed");
			scope (success)
				writefln("success");

			MockRepository r = new MockRepository();
			r.Match!()(new FakeMocked, "toString");
		}

		unittest {
			writef("repository match unit test...");
			scope (failure)
				writefln("failed");
			scope (success)
				writefln("success");
			FakeMocked m = new FakeMocked();
			char[] name = "Tom Jones";
			int args = 3;

			MockRepository r = new MockRepository();
			r.Record!(int)(m, name, args, false);
			r.Record!(int)(m, name, args, false);
			ICall call = r.Match!(int)(m, name, args);
			assert (call !is null);
			call = r.Match!(int)(m, name, args + 5);
			assert (call is null);
		}

		unittest {
			writef("repository match ignore arguments unit test...");
			scope (failure)
				writefln("failed");
			scope (success)
				writefln("success");
			FakeMocked m = new FakeMocked();
			char[] name = "Tom Jones";
			int args = 3;

			MockRepository r = new MockRepository();
			r.Record!(int)(m, name, args, false);
			r.Record!(int)(m, name, args, false);
			r._lastCall.IgnoreArguments = true;
			ICall call = r.Match!(int)(m, name, args);
			assert (call !is null);
			call = r.Match!(int)(m, name, args + 5);
			assert (call !is null);
		}

		unittest {
			writef("repository match counts unit test...");
			scope (failure)
				writefln("failed");
			scope (success)
				writefln("success");
			FakeMocked m = new FakeMocked();
			char[] name = "Tom Jones";
			int args = 3;

			MockRepository r = new MockRepository();
			r.Record!(int)(m, name, args, false);
			ICall call = r.Match!(int)(m, name, args);
			assert (call !is null);
			try
			{
				call = r.Match!(int)(m, name, args);
				assert (false, "expected exception not called");
			}
			catch (ExpectationViolationException e)
			{
			}
		}
	}
}
}

version (MocksTest)
{
	unittest {
		writef("argument equality unit test...");
		scope (failure)
			writefln("failed");
		scope (success)
			writefln("success");
		auto a = new Arguments!(int, real)(5, 9.7);
		auto b = new Arguments!(int, real)(5, 9.7);
		auto c = new Arguments!(int, real)(9, 1.1);
		auto d = new Arguments!(int, float)(5, 9.7f);

		assert (a == b);
		assert (a != c);
		assert (a != d);
	}

	unittest {
		writef("argument toString unit test...");
		scope (failure)
			writefln("failed");
		scope (success)
			writefln("success");
		auto a = new Arguments!(int, real)(5, 9.7);
		a.toString();
	}
}
