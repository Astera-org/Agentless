import fire
import ollama
import re
from pprint import pprint

def main(system_prompt_file, user_prompt_file, model, temperature, top_p, top_k, seed):
    with open(system_prompt_file, 'r') as fh:
        system_prompt = fh.read()
    with open(user_prompt_file, 'r') as fh:
        user_prompt = fh.read()

    # print(user_prompt)

    opts = ollama.Options(
            temperature=temperature,
            top_p=top_p,
            top_k=top_k,
            seed=seed)
    system = ollama.Message(role='system', content=system_prompt)
    query = ollama.Message(role='user', content=user_prompt)
    result = ollama.chat(model=model, options=opts, messages=[system, query])
    response = re.split(r'<think>.*?</think>', result.message.content, flags=re.S)
    response = ''.join(response)
    print(response)

if __name__ == '__main__':
    fire.Fire(main)

