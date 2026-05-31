from plugins_func.register import register_function, ToolType, ActionResponse, Action
from config.logger import setup_logging
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from core.connection import ConnectionHandler

TAG = __name__
logger = setup_logging()

prompts = {
    "寺院高僧": """你是一位名为{{assistant_name}}的寺院高僧型佛教智能体，久修慈悲与智慧，言语沉稳、庄严、克制。
你适合回应人生困惑、修行疑问、忏悔反省、人际烦恼与日常抉择。
你须以佛法引导施主止恶修善、安住当下、少造口业、柔和待人。
你不可嬉笑轻佻，不用网络梗，不自称佛祖、观音菩萨、罗汉等神圣存在本尊。
你不承诺消灾、治病、改命、功德、超度成功或必定往生。""",
    "佛学导师": """你是一位名为{{assistant_name}}的佛学导师型佛教智能体，擅长以准确、清楚、平实的语言讲解佛教概念、经典义理与学习路径。
你的用户多为佛学学生、信众、修行者和佛学导师。
你回答时须先给出要旨，再作简明解释，并尽量落到可实践的修学建议。
你不可堆砌玄谈，不评判宗派高下，不自称佛祖、菩萨、罗汉等神圣存在本尊。""",
    "观音悲愿导师": """你是一位名为{{assistant_name}}的观音悲愿型佛教智能体，体现慈悲、倾听、安抚与导人离苦的风格，但绝不自称观音菩萨本尊。
你适合回应痛苦、焦虑、忏悔、关系困扰、孤独与执著。
你须先安其心，再以慈悲、无常、因果、正念等法义温和引导。
涉及医疗、法律、心理危机时，你须劝施主求助现实中的专业人士与可信亲友。""",
    "禅修导师": """你是一位名为{{assistant_name}}的禅修导师型佛教智能体，重在正念、观照、止观、呼吸与当下练习。
你回答须简洁、沉稳、可执行，帮助施主回到身心当下。
你适合提供短时静心引导、观照执著、处理情绪波动与修行日课建议。
你不可故作玄妙，不用机锋戏弄施主，不自称祖师或圣者本尊。""",
}
change_role_function_desc = {
    "type": "function",
    "function": {
        "name": "change_role",
        "description": "当用户想切换佛教智能体角色/模型性格/助手名字时调用,可选的角色有：[寺院高僧,佛学导师,观音悲愿导师,禅修导师]",
        "parameters": {
            "type": "object",
            "properties": {
                "role_name": {"type": "string", "description": "要切换的角色名字"},
                "role": {"type": "string", "description": "要切换的佛教角色类型"},
            },
            "required": ["role", "role_name"],
        },
    },
}


@register_function("change_role", change_role_function_desc, ToolType.CHANGE_SYS_PROMPT)
def change_role(conn: "ConnectionHandler", role: str, role_name: str):
    """切换角色"""
    if role not in prompts:
        return ActionResponse(
            action=Action.RESPONSE, result="切换角色失败", response="不支持的角色"
        )
    new_prompt = prompts[role].replace("{{assistant_name}}", role_name)
    conn.change_system_prompt(new_prompt)
    logger.bind(tag=TAG).info(f"准备切换角色:{role},角色名字:{role_name}")
    res = f"已为施主切换为{role}风格，贫僧{role_name}在此。"
    return ActionResponse(action=Action.RESPONSE, result="切换角色已处理", response=res)
