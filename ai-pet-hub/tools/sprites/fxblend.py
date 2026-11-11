"""中间帧的特效（光环、气泡、星星、光晕）不用画出来的，直接沿用前一张原图的特效。
画出来的半透明细线经过绿幕抠图会发虚、偏色；原图的特效干净；特效每两帧换一次，和原来 4 帧的节奏一样，不会有重影。
角色本体（画出来的帧里最大的那一块，往外扩 3px）保留画出来的。
用法：python fxblend.py mid.png prev.png next.png out.png [basebody]
"""
import sys
import numpy as np
from PIL import Image
from scipy.ndimage import label, binary_dilation

mid_p, a_p, b_p, out_p = sys.argv[1:5]
M = np.asarray(Image.open(mid_p).convert('RGBA')).astype(np.float32) / 255
A = np.asarray(Image.open(a_p).convert('RGBA')).astype(np.float32) / 255
B = np.asarray(Image.open(b_p).convert('RGBA')).astype(np.float32) / 255

def body_mask(img):
    solid = img[..., 3] > 0.5
    lab, n = label(solid)
    big = np.argmax(np.bincount(lab.ravel())[1:]) + 1
    return binary_dilation(lab == big, iterations=3)

# basebody：人物范围按底图（prev）的轮廓算。画出来的特效常和头发连在一起，按新帧算会被当成身体留下来；
# 在人物整体不动、只动手的动作里，用底图的轮廓更准。
body = body_mask(A) if len(sys.argv) > 5 and sys.argv[5] == 'basebody' else body_mask(M)
# 前后两帧的特效：各自去掉本体以后剩下的部分，预乘 alpha 后平均
def fx(img):
    keep = ~body_mask(img)
    pre = img[..., :3] * img[..., 3:4]
    return pre * keep[..., None], img[..., 3] * keep
pa, aa = fx(A)
pb, ab = fx(B)
# 只用前一帧的特效（不和后一帧平均）：两帧特效位置不同时，平均会叠出重影
fx_pre, fx_a = pa, aa
# 合成：本体用画出来的；本体以外用平均特效
out_a = np.where(body, M[..., 3], fx_a)
out_pre = np.where(body[..., None], M[..., :3] * M[..., 3:4], fx_pre)
rgb = np.where(out_a[..., None] > 1e-4, out_pre / np.maximum(out_a[..., None], 1e-4), 0)
out = np.dstack([rgb, out_a]).clip(0, 1)
Image.fromarray((out * 255).round().astype(np.uint8), 'RGBA').save(out_p, optimize=True)
print(f'{out_p.split("/")[-1]}: 本体 {body.mean() * 100:.0f}% 画面，其余沿用前一帧特效')
