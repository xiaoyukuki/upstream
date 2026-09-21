shader_type canvas_item;

// 冻结态滤镜（D46）。两条抽头指向同一张屏幕纹理，只是采样器不同：
// nearest 给硬边、linear 给软边，色散那对红蓝偏移走 linear 才糊得出来。
// 用 hint_screen_texture 而不是外部喂图 = D8 定的路线：不加 SubViewport、
// 不建渲染目标，滤镜这一层从头到尾不参与冻结判定。
uniform sampler2D viewport_nearest : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D viewport_linear : hint_screen_texture, filter_linear, repeat_disable;

// 淡入淡出的总量，由 TimeFreezeFilter 每帧写进来。旧版这条挂在 ColorRect 的 alpha 上，
// 而 shader 一覆盖 COLOR 就把顶点色丢了 —— 所以换成混音比：0 = 原样拷回屏幕，1 = 全量。
uniform float strength = 1.0;

uniform float scan_line_fac = 0.1;
uniform float scan_line_width = 0.25;
uniform float nearest_fac = 0.0;
uniform float linear_fac = 1.3;
uniform bool aberration_enabled = true;

const float ABERRATION_FAC = 0.001;
// 晶格按 320×180 写死：1280×720 窗口下正好一格 4 设备像素（= 2 世界像素，相机 zoom 2）。
// 窗口拉成非整数倍时这道格会跟 16 px 网格打摩尔纹，这是这条路线的已知代价。
const vec2 RESOLUTION = vec2(320.0, 180.0);

// 采样一律用 SCREEN_UV 不用 UV：UV 是「本像素在这块 ColorRect 里的位置」，
// 而屏幕纹理要的是「在整张屏幕上的位置」。rect 挪动或不满屏时两者就会错开，
// 而现在这块恰好铺满，写成 SCREEN_UV 是为了以后不靠这个巧合。
//
// 结构上没有提前 return：Godot 的着色器语言不允许 fragment() 里 return（实测 SHADER ERROR），
// 所以走「局部变量算完、末尾一次写 COLOR」这条。strength == 0 时那个分支整个跳过 = 原样拷回屏幕。
void fragment() {
	vec3 out_color = texture(viewport_nearest, SCREEN_UV).rgb;
	if (strength > 0.0) {
		float fy = fract(SCREEN_UV * RESOLUTION).y;
		float scan = (fy < scan_line_width || fy > 1.0 - scan_line_width) ? scan_line_fac : 0.0;
		float chroma = aberration_enabled ? 1.0 : 0.0;
		vec3 c;
		c.r = texture(viewport_linear, SCREEN_UV - vec2(chroma * ABERRATION_FAC, 0.0)).r;
		c.g = texture(viewport_linear, SCREEN_UV).g;
		c.b = texture(viewport_linear, SCREEN_UV + vec2(chroma * ABERRATION_FAC, 0.0)).b;
		c = mix(c * linear_fac, vec3(0.0), scan);
		c += out_color * nearest_fac;
		out_color = mix(out_color, c, strength);
	}
	COLOR = vec4(out_color, 1.0);
}
