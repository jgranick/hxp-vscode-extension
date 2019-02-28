package hxp.extension;

import js.node.Buffer;
import js.node.ChildProcess;
import sys.FileSystem;
import haxe.io.Path;
import haxe.DynamicAccess;
import Vscode.*;
import vscode.*;

using hxp.extension.ArrayHelper;
using Lambda;

class Main
{
	private static var instance:Main;

	private var buildConfigItems:Array<BuildConfigItem>;
	private var context:ExtensionContext;
	private var displayArgumentsProvider:HXPDisplayArgumentsProvider;
	private var disposables:Array<{function dispose():Void;}>;
	private var editTargetFlagsItem:StatusBarItem;
	private var initialized:Bool;
	private var isProviderActive:Bool;
	private var targetItems:Array<TargetItem>;
	private var haxeEnvironment:DynamicAccess<String>;
	private var hxpExecutable:String;

	public function new(context:ExtensionContext)
	{
		this.context = context;

		context.subscriptions.push(workspace.onDidChangeConfiguration(workspace_onDidChangeConfiguration));
		refresh();
	}

	private function construct():Void
	{
		disposables = [];

		editTargetFlagsItem = window.createStatusBarItem(Left, 7);
		editTargetFlagsItem.command = "hxp.editTargetFlags";
		disposables.push(editTargetFlagsItem);

		disposables.push(commands.registerCommand("hxp.editTargetFlags", editTargetFlagsItem_onCommand));

		disposables.push(tasks.registerTaskProvider("hxp", this));
	}

	private function deconstruct():Void
	{
		if (disposables == null)
		{
			return;
		}

		for (disposable in disposables)
		{
			disposable.dispose();
		}

		editTargetFlagsItem = null;

		disposables = null;
		initialized = false;
	}

	private function constructDisplayArgumentsProvider()
	{
		var api:Vshaxe = getVshaxe();

		displayArgumentsProvider = new HXPDisplayArgumentsProvider(api, function(isProviderActive)
		{
			this.isProviderActive = isProviderActive;
			refresh();
		});

		if (untyped !api)
		{
			trace("Warning: Haxe language server not available (using an incompatible vshaxe version)");
		}
		else
		{
			api.registerDisplayArgumentsProvider("HXP", displayArgumentsProvider);
		}
	}

	private inline function getVshaxe():Vshaxe
	{
		return extensions.getExtension("nadako.vshaxe").exports;
	}

	private function createTask(description:String, command:String, ?group:TaskGroup)
	{
		var definition:HXPTaskDefinition =
			{
				type: "hxp",
				command: command
			}

		// var task = new Task (definition, description, "HXP");
		var args = getCommandArguments(command);
		var name = args.join(" ");

		var vshaxe = getVshaxe();
		var displayPort = vshaxe.displayPort;
		if (getVshaxe().enableCompilationServer && displayPort != null && args.indexOf("--connect") == -1)
		{
			args.push("--connect");
			args.push(Std.string(displayPort));
		}

		var task = new Task(definition, TaskScope.Workspace, name, "hxp");

		task.execution = new ShellExecution(hxpExecutable + " " + args.join(" "),
			{cwd: workspace.workspaceFolders[0].uri.fsPath, env: haxeEnvironment});

		if (group != null)
		{
			task.group = group;
		}

		task.problemMatchers = vshaxe.problemMatchers.get();

		var presentation = vshaxe.taskPresentation;
		task.presentationOptions =
			{
				reveal: presentation.reveal,
				echo: presentation.echo,
				focus: presentation.focus,
				panel: presentation.panel,
				showReuseMessage: presentation.showReuseMessage,
				clear: presentation.clear
			};
		return task;
	}

	public function getBuildConfigFlags():String
	{
		var defaultFlags = "";
		var defaultBuildConfigLabel = workspace.getConfiguration("hxp").get("defaultBuildConfiguration", "Release");
		var defaultBuildConfig = buildConfigItems.find(function(item) return item.label == defaultBuildConfigLabel);
		if (defaultBuildConfig != null)
		{
			defaultFlags = defaultBuildConfig.flags;
		}

		return context.workspaceState.get("hxp.buildConfigFlags", defaultFlags);
	}

	private function getExecutable():String
	{
		var executable = workspace.getConfiguration("hxp").get("executable");
		if (executable == null)
		{
			executable = "hxp";
		}
		// naive check to see if it's a path, or multiple arguments such as "haxelib run hxp"
		if (FileSystem.exists(executable))
		{
			executable = '"' + executable + '"';
		}
		return executable;
	}

	private function getCommandArguments(command:String):Array<String>
	{
		var args = [command];

		// TODO: Support rebuild tools (and other command with no project file argument)

		var projectFile = getProjectFile();
		if (projectFile != "") args.push(projectFile);
		args.push(getTarget());

		var buildConfigFlags = getBuildConfigFlags();
		if (buildConfigFlags != "")
		{
			// TODO: Handle argument list better
			args = args.concat(buildConfigFlags.split(" "));
		}

		var targetFlags = StringTools.trim(getTargetFlags());
		if (targetFlags != "")
		{
			// TODO: Handle argument list better
			args = args.concat(targetFlags.split(" "));
		}

		return args;
	}

	public function getProjectFile():String
	{
		var config = workspace.getConfiguration("hxp");

		if (config.has("projectFile"))
		{
			var projectFile = Std.string(config.get("projectFile"));
			if (projectFile == "null") projectFile = "";
			return projectFile;
		}
		else
		{
			return "";
		}
	}

	public function getTarget():String
	{
		var defaultTarget = "html5";
		var defaultTargetLabel = workspace.getConfiguration("hxp").get("defaultTarget", "HTML5");
		var defaultTargetItem = targetItems.find(function(item) return item.label == defaultTargetLabel);
		if (defaultTargetItem != null)
		{
			defaultTarget = defaultTargetItem.target;
		}

		return context.workspaceState.get("hxp.target", defaultTarget);
	}

	public function getTargetFlags():String
	{
		return context.workspaceState.get("hxp.additionalTargetFlags", "");
	}

	private function initialize():Void
	{
		// TODO: Populate target items and build configurations from HXP

		targetItems = [
			{
				target: "android",
				label: "Android",
				description: "",
			},
			{
				target: "flash",
				label: "Flash",
				description: "",
			},
			{
				target: "html5",
				label: "HTML5",
				description: "",
			},
			{
				target: "neko",
				label: "Neko",
				description: "",
			},
			{
				target: "emscripten",
				label: "Emscripten",
				description: "",
			}
		];

		switch (Sys.systemName())
		{
			case "Windows":
				targetItems.unshift(
					{
						target: "windows",
						label: "Windows",
						description: "",
					});

				targetItems.push(
					{
						target: "air",
						label: "AIR",
						description: "",
					});

				targetItems.push(
					{
						target: "electron",
						label: "Electron",
						description: "",
					});

			case "Linux":
				targetItems.unshift(
					{
						target: "linux",
						label: "Linux",
						description: "",
					});

			case "Mac":
				targetItems.unshift(
					{
						target: "mac",
						label: "macOS",
						description: "",
					});

				targetItems.unshift(
					{
						target: "ios",
						label: "iOS",
						description: "",
					});

				targetItems.push(
					{
						target: "air",
						label: "AIR",
						description: "",
					});

				targetItems.push(
					{
						target: "electron",
						label: "Electron",
						description: "",
					});
		}

		buildConfigItems = [
			{
				flags: "-debug",
				label: "Debug",
				description: "",
			},
			{
				flags: "",
				label: "Release",
				description: "",
			},
			{
				flags: "-final",
				label: "Final",
				description: "",
			}
		];

		getVshaxe().haxeExecutable.onDidChangeConfiguration(function(_) updateHaxeEnvironment());
		updateHaxeEnvironment();

		initialized = true;
	}

	private function updateHaxeEnvironment()
	{
		var haxeConfiguration = getVshaxe().haxeExecutable.configuration;
		var env = new DynamicAccess();

		for (field in Reflect.fields(haxeConfiguration.env))
		{
			env[field] = haxeConfiguration.env[field];
		}

		if (!haxeConfiguration.isCommand)
		{
			var separator = Sys.systemName() == "Windows" ? ";" : ":";
			env["PATH"] = Path.directory(haxeConfiguration.executable) + separator + Sys.getEnv("PATH");
		}

		haxeEnvironment = env;
	}

	@:keep @:expose("activate") public static function activate(context:ExtensionContext)
	{
		instance = new Main(context);
	}

	@:keep @:expose("deactivate") public static function deactivate()
	{
		instance.deconstruct();
	}

	static function main() {}

	public function provideTasks(?token:CancellationToken):ProviderResult<Array<Task>>
	{
		var tasks = [
			createTask("Clean", "clean", TaskGroup.Clean),
			createTask("Update", "update"),
			createTask("Build", "build", TaskGroup.Build),
			createTask("Run", "run"),
			createTask("Test", "test", TaskGroup.Test),
		];

		var target = getTarget();

		// TODO: Detect HXP development build

		if (target != "html5" && target != "flash")
		{
			// tasks.push (createTask ("Rebuild", "rebuild", TaskGroup.Rebuild));
		}

		// tasks.push (createTask ("Rebuild", "rebuild tools", TaskGroup.Rebuild));

		return tasks;
	}

	private function refresh():Void
	{
		if (displayArgumentsProvider == null)
		{
			constructDisplayArgumentsProvider();
		}

		var oldHXPExecutable = hxpExecutable;
		hxpExecutable = getExecutable();
		var hxpExecutableChanged = oldHXPExecutable != hxpExecutable;

		if (isProviderActive && (!initialized || hxpExecutableChanged))
		{
			if (!initialized)
			{
				initialize();
				construct();
			}

			updateDisplayArguments();
		}

		if (!isProviderActive)
		{
			deconstruct();
		}

		if (initialized)
		{
			updateStatusBarItems();
		}
	}

	public function resolveTask(task:Task, ?token:CancellationToken):ProviderResult<Task>
	{
		return task;
	}

	public function setBuildConfigFlags(flags:String):Void
	{
		context.workspaceState.update("hxp.buildConfigFlags", flags);
		updateStatusBarItems();
		updateDisplayArguments();
	}

	public function setTarget(target:String):Void
	{
		context.workspaceState.update("hxp.target", target);
		updateStatusBarItems();
		updateDisplayArguments();
	}

	public function setTargetFlags(flags:String):Void
	{
		context.workspaceState.update("hxp.additionalTargetFlags", flags);
		updateStatusBarItems();
		updateDisplayArguments();
	}

	private function updateDisplayArguments():Void
	{
		if (!isProviderActive) return;

		var commandLine = hxpExecutable + " " + getCommandArguments("display").join(" ");
		commandLine = StringTools.replace(commandLine, "-verbose", "");

		ChildProcess.exec(commandLine,
			{cwd: workspace.workspaceFolders[0].uri.fsPath}, function(err, stdout:Buffer, stderror)
		{
			if (err != null && err.code != 0)
			{
				var message = 'HXP completion setup failed. Is the hxp command available? Try running "hxp setup" or changing the "hxp.executable" setting.';
				var showFullErrorLabel = "Show Full Error";
				window.showErrorMessage(message, showFullErrorLabel).then(function(selection)
				{
					if (selection == showFullErrorLabel)
					{
						commands.executeCommand("workbench.action.toggleDevTools");
					}
				});
				trace(err);
			}
			else
			{
				displayArgumentsProvider.update(stdout.toString());
			}
		});
	}

	private function updateStatusBarItems():Void
	{
		if (isProviderActive)
		{
			editTargetFlagsItem.text = "$(list-unordered)";
			editTargetFlagsItem.tooltip = "Edit Target Flags";
			var flags = getTargetFlags();
			if (flags.length != 0)
			{
				editTargetFlagsItem.tooltip += ' ($flags)';
			}
			editTargetFlagsItem.show();
		}
		else
		{
			editTargetFlagsItem.hide();
		}
	}

	// Event Handlers
	private function editTargetFlagsItem_onCommand():Void
	{
		var flags = getTargetFlags();
		var value = if (flags.length == 0) "" else flags + " ";
		window.showInputBox({prompt: "Target Flags", value: value, valueSelection: [flags.length + 1, flags.length + 1]}).then(function(newValue:String)
		{
			if (newValue != null)
			{
				setTargetFlags(StringTools.trim(newValue));
			}
		});
	}

	private function workspace_onDidChangeConfiguration(_):Void
	{
		refresh();
	}
}

private typedef HXPTaskDefinition =
{
	> TaskDefinition,
	var command:String;
}

private typedef TargetItem =
{
	> QuickPickItem,
	var target:String;
}

private typedef BuildConfigItem =
{
	> QuickPickItem,
	var flags:String;
}
