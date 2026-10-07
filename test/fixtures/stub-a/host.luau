--!strict
-- Test fixture block for dir-blocks' test/e2e.sh and README screenshot: shows its own name.
tern.block.define("panel", {
	init = function(_cx: BlockCx, _args: { string }, _saved: any): { string }
		return { "stub-a" }
	end,
	view = function(state: { string }, _cx: BlockCx): BlockView
		return {
			main = tern.ui.col({
				tern.ui.card({ tern.ui.span(state[1], "bold") }, {
					tern.ui.text("A fixture block, opened by dir-blocks."),
				}),
			}),
		}
	end,
})
